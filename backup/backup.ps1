# =====================================================================
#  院内Webサーバー 日次バックアップ
#    MySQL（DBごとのダンプ）/ SQLite（オンラインバックアップ）/ 指定フォルダ・ファイル
#    を NAS の daily\yyyyMMdd_HHmm\ に保存し、世代管理と検証を行う。
#
#  手動実行:  powershell -NoProfile -ExecutionPolicy Bypass -File C:\backup\scripts\backup.ps1
#  終了コード: 0 = 成功（警告ありを含む）/ 1 = 失敗
# =====================================================================
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.ps1')
)

. (Join-Path $PSScriptRoot 'common.ps1')
. $ConfigPath
$C = $BackupConfig

$stamp     = Get-Date -Format 'yyyyMMdd_HHmmss'
$startedAt = Get-Date
$errors    = New-Object System.Collections.Generic.List[string]
$warnings  = New-Object System.Collections.Generic.List[string]
$manifest  = [ordered]@{
    Stamp = $stamp; Host = $env:COMPUTERNAME; StartedAt = $startedAt.ToString('s')
    FinishedAt = $null; Status = $null
    Versions = [ordered]@{}; MySql = @(); MySqlGrantsFile = $null; Sqlite = @(); Items = @()
    Errors = @(); Warnings = @()
}

function Add-Error([string]$m)   { $errors.Add($m);   Write-Log $m 'ERROR' }
function Add-Warning([string]$m) { $warnings.Add($m); Write-Log $m 'WARN' }

Initialize-Log -Dir $C.LocalLogDir -Prefix 'backup' | Out-Null
Write-Log "バックアップ開始 $stamp"

# ---- 二重起動防止（プロセスが落ちればロックも自動で外れる） -------------
if (-not (Test-Path -LiteralPath $C.LocalWorkDir)) { New-Item -ItemType Directory -Path $C.LocalWorkDir -Force | Out-Null }
try {
    $lock = [System.IO.File]::Open((Join-Path $C.LocalWorkDir 'backup.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
    Write-Log '別のバックアップが実行中のため終了します' 'ERROR'
    exit 1
}

$setDir = $null
try {
    # ---- NAS 接続確認 --------------------------------------------------
    if (-not (Test-Path -LiteralPath $C.NasRoot)) { throw "NAS に接続できません: $($C.NasRoot)" }
    $dailyRoot = Join-Path $C.NasRoot 'daily'
    New-Item -ItemType Directory -Path $dailyRoot -Force | Out-Null
    $setDir = Join-Path $dailyRoot ($stamp + '.partial')
    New-Item -ItemType Directory -Path $setDir -Force | Out-Null

    # 前回成功分（縮小チェック用）
    $prevManifest = $null
    $prevSet = Get-BackupSets -NasRoot $C.NasRoot | Where-Object { $_.Kind -eq 'daily' } | Select-Object -First 1
    if ($prevSet) { try { $prevManifest = Read-Manifest -SetPath $prevSet.Path } catch { } }

    # ローカル作業フォルダ（直近1世代のDBダンプがここに残る）
    $stage = Join-Path $C.LocalWorkDir 'latest'
    if (Test-Path -LiteralPath $stage) { Remove-DirectoryRobust -Path $stage }
    New-Item -ItemType Directory -Path (Join-Path $stage 'mysql'), (Join-Path $stage 'sqlite') -Force | Out-Null

    # ---- バージョン記録 ------------------------------------------------
    $verTargets = [ordered]@{ Apache = @($C.ApacheExe, '-v'); Php = @($C.PhpExe, '-v') }
    if ($C.MySqlEnabled) { $verTargets.MySql = @((Join-Path $C.MySqlBinDir 'mysql.exe'), '--version') }
    if ($C.SqliteEnabled) { $verTargets.Sqlite = @($C.SqliteExe, '-version') }
    foreach ($k in $verTargets.Keys) {
        $exe = $verTargets[$k][0]
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            try { $manifest.Versions[$k] = (Invoke-Native -Exe $exe -Arguments @($verTargets[$k][1])).Output[0].Trim() } catch { }
        }
    }

    # ---- MySQL ---------------------------------------------------------
    if ($C.MySqlEnabled) {
        try {
            Assert-Tool -Path $C.MySqlDefaultsFile -Label 'MySQL 接続設定ファイル'
            $mysqldump = Get-MySqlExe -Config $C -Name 'mysqldump.exe'

            $schemaRows = Invoke-MySqlQuery -Config $C -DefaultsFile $C.MySqlDefaultsFile -Query `
                'SELECT SCHEMA_NAME, DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA ORDER BY SCHEMA_NAME'
            $schemas = @{}
            foreach ($row in $schemaRows) { $f = $row -split "`t"; $schemas[$f[0]] = $f }

            if ($C.MySqlDatabases.Count -gt 0) {
                $dbs = $C.MySqlDatabases
                foreach ($d in $dbs) { if (-not $schemas.ContainsKey($d)) { Add-Error "MySQL: DB '$d' が存在しません" } }
                $dbs = @($dbs | Where-Object { $schemas.ContainsKey($_) })
            } else {
                $dbs = @($schemas.Keys | Where-Object { $C.MySqlExcludeDatabases -notcontains $_ } | Sort-Object)
            }
            if ($dbs.Count -eq 0) { Add-Warning 'MySQL: バックアップ対象のDBがありません' }

            foreach ($db in $dbs) {
                $out = Join-Path $stage "mysql\$db.sql"
                Write-Log "MySQL ダンプ: $db"
                # 出力は --result-file で直接書く（PowerShell のパイプを通すと文字コードが変わるため）
                $r = Invoke-Native -Exe $mysqldump -Arguments @("--defaults-extra-file=$($C.MySqlDefaultsFile)",
                    '--single-transaction', '--quick', '--routines', '--triggers', '--events',
                    '--hex-blob', '--default-character-set=utf8mb4', "--result-file=$out", $db)
                if ($r.ExitCode -ne 0) { Add-Error "MySQL: $db のダンプ失敗: $($r.Text)"; continue }
                $last = Get-Content -LiteralPath $out -Tail 1 -Encoding UTF8
                if ((Get-Item -LiteralPath $out).Length -eq 0 -or $last -notmatch 'Dump completed') {
                    Add-Error "MySQL: $db のダンプが途中で終わっています"; continue
                }
                $manifest.MySql += [ordered]@{
                    Database = $db; File = "mysql\$db.sql"; Size = (Get-Item -LiteralPath $out).Length
                    Sha256 = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash
                    Charset = $schemas[$db][1]; Collation = $schemas[$db][2]
                }
            }

            # アカウントの権限（パスワードは含まない。新サーバーに作り直すときの参考）
            try {
                $users = Invoke-MySqlQuery -Config $C -DefaultsFile $C.MySqlDefaultsFile -Query `
                    "SELECT CONCAT(QUOTE(user),'@',QUOTE(host)) FROM mysql.user WHERE user NOT IN ('root','mysql','mysql.sys','mysql.session','mysql.infoschema','mariadb.sys','PUBLIC','') ORDER BY user"
                $lines = @('-- MySQL アカウントと権限の控え（MySQLではパスワードは含まれません。MariaDBではGRANT行にパスワードのハッシュが含まれます）', '-- 復元時は <パスワード> を書き換えてから、必要な行だけ実行してください', '')
                foreach ($u in $users) {
                    $lines += "CREATE USER IF NOT EXISTS $u IDENTIFIED BY '<パスワード>';"
                    $lines += (Invoke-MySqlQuery -Config $C -DefaultsFile $C.MySqlDefaultsFile -Query "SHOW GRANTS FOR $u" | ForEach-Object { "$_;" })
                    $lines += ''
                }
                [System.IO.File]::WriteAllLines((Join-Path $stage 'mysql\_grants.sql'), [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
                $manifest.MySqlGrantsFile = 'mysql\_grants.sql'
            } catch { Add-Warning "MySQL: アカウント権限の控えを取得できませんでした: $($_.Exception.Message)" }
        } catch { Add-Error "MySQL: $($_.Exception.Message)" }
    }

    # ---- SQLite --------------------------------------------------------
    if ($C.SqliteEnabled) {
        try {
            Assert-Tool -Path $C.SqliteExe -Label 'sqlite3.exe'
            $files = @{}
            foreach ($f in $C.SqliteFiles) {
                if (Test-Path -LiteralPath $f -PathType Leaf) { $files[(Resolve-Path -LiteralPath $f).Path] = $true }
                else { Add-Error "SQLite: ファイルがありません: $f" }
            }
            foreach ($root in $C.SqliteSearchRoots) {
                if (-not (Test-Path -LiteralPath $root)) { continue }
                Get-ChildItem -LiteralPath $root -Recurse -File -Include $C.SqliteSearchPatterns -ErrorAction SilentlyContinue |
                    Where-Object { Test-SqliteFile -Path $_.FullName } | ForEach-Object { $files[$_.FullName] = $true }
            }
            foreach ($src in ($files.Keys | Sort-Object)) {
                $name = ConvertTo-SafeName -Path $src
                $out = Join-Path $stage "sqlite\$name"
                Write-Log "SQLite バックアップ: $src"
                # .backup は書き込み中でも整合性のあるコピーを作る（ロック待ちは最大30秒）
                $journal = (Invoke-Native -Exe $C.SqliteExe -Arguments @('-cmd', '.timeout 30000', $src, 'PRAGMA journal_mode;')).Text.Trim().ToLower()
                if ($journal -notmatch '^(delete|truncate|persist|memory|wal|off)$') { $journal = $null }
                $r = Invoke-Native -Exe $C.SqliteExe -Arguments @('-bail', '-cmd', '.timeout 30000', $src, ".backup '$(ConvertTo-SqlitePath $out)'")
                if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $out)) { Add-Error "SQLite: $src のバックアップ失敗: $($r.Text)"; continue }
                # コピーは単体ファイルで完結するよう DELETE モードにする（-wal/-shm を作らない。元のモードは復元時に戻す）
                Invoke-Native -Exe $C.SqliteExe -Arguments @($out, 'PRAGMA journal_mode=DELETE;') | Out-Null
                $check = (Invoke-Native -Exe $C.SqliteExe -Arguments @($out, 'PRAGMA integrity_check;')).Text
                if ($check.Trim() -ne 'ok') { Add-Error "SQLite: $src の整合性チェック失敗: $check"; continue }
                $manifest.Sqlite += [ordered]@{
                    Source = $src; File = "sqlite\$name"; JournalMode = $journal; Size = (Get-Item -LiteralPath $out).Length
                    Sha256 = (Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash
                }
            }
            if ($files.Count -eq 0) { Add-Warning 'SQLite: バックアップ対象のファイルが見つかりません' }
        } catch { Add-Error "SQLite: $($_.Exception.Message)" }
    }

    # ---- DBダンプを NAS へ転送してハッシュ照合 ------------------------
    try {
        Invoke-Robocopy -Source $stage -Destination $setDir | Out-Null
        foreach ($e in @($manifest.MySql) + @($manifest.Sqlite)) {
            $h = (Get-FileHash -LiteralPath (Join-Path $setDir $e.File) -Algorithm SHA256).Hash
            if ($h -ne $e.Sha256) { Add-Error "NAS 転送後のハッシュ不一致: $($e.File)" }
        }
    } catch { Add-Error "NAS 転送: $($_.Exception.Message)" }

    # ---- フォルダ・ファイル --------------------------------------------
    foreach ($item in $C.Items) {
        try {
            if (-not (Test-Path -LiteralPath $item.Path)) { Add-Error "ファイル: 対象がありません: $($item.Path)"; continue }
            $isFile = Test-Path -LiteralPath $item.Path -PathType Leaf
            $dest = Join-Path $setDir ('files\' + $item.Name)
            Write-Log "コピー: $($item.Path) -> files\$($item.Name)"
            $exclude = @(); if ($item.Exclude) { $exclude = $item.Exclude }
            Copy-Item-Robust -Source $item.Path -DestinationDir $dest -ExcludeFiles $exclude
            $stat = Get-ChildItem -LiteralPath $dest -Recurse -File -Force | Measure-Object -Property Length -Sum
            $manifest.Items += [ordered]@{
                Name = $item.Name; Path = $item.Path; Type = $(if ($isFile) { 'File' } else { 'Directory' })
                FileCount = $stat.Count; TotalBytes = [int64]$stat.Sum; Exclude = @($exclude)
            }
        } catch { Add-Error "ファイル: $($item.Name): $($_.Exception.Message)" }
    }

    # ---- 前回からの急な縮小を警告（誤削除・ランサムウェアの早期発見） --
    if ($prevManifest) {
        $r = $C.ShrinkWarnRatio
        foreach ($m in $manifest.MySql) {
            $p = @($prevManifest.MySql | Where-Object { $_.Database -eq $m.Database }) | Select-Object -First 1
            if ($p -and $p.Size -gt 0 -and $m.Size -lt $p.Size * $r) { Add-Warning "MySQL: $($m.Database) のダンプが前回より大きく減少 ($($p.Size) -> $($m.Size) bytes)" }
        }
        foreach ($m in $manifest.Sqlite) {
            $p = @($prevManifest.Sqlite | Where-Object { $_.Source -eq $m.Source }) | Select-Object -First 1
            if ($p -and $p.Size -gt 0 -and $m.Size -lt $p.Size * $r) { Add-Warning "SQLite: $($m.Source) が前回より大きく減少 ($($p.Size) -> $($m.Size) bytes)" }
        }
        foreach ($m in $manifest.Items) {
            $p = @($prevManifest.Items | Where-Object { $_.Name -eq $m.Name }) | Select-Object -First 1
            if ($p -and $p.FileCount -gt 0 -and $m.FileCount -lt $p.FileCount * $r) { Add-Warning "ファイル: $($m.Name) のファイル数が前回より大きく減少 ($($p.FileCount) -> $($m.FileCount))" }
        }
        foreach ($p in @($prevManifest.MySql)) {
            if (-not ($manifest.MySql | Where-Object { $_.Database -eq $p.Database })) { Add-Warning "MySQL: 前回あった DB '$($p.Database)' が今回ありません" }
        }
    }
} catch {
    Add-Error $_.Exception.Message
}

# ---- 仕上げ：manifest、フォルダ名確定、世代管理 --------------------------
$ok = ($errors.Count -eq 0)
$manifest.FinishedAt = (Get-Date).ToString('s')
$manifest.Status = $(if ($ok) { 'OK' } else { 'FAILED' })
$manifest.Errors = @($errors); $manifest.Warnings = @($warnings)
$finalDir = $null

if ($setDir -and (Test-Path -LiteralPath $setDir)) {
    try {
        [System.IO.File]::WriteAllText((Join-Path $setDir 'manifest.json'), ($manifest | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        $finalName = $(if ($ok) { $stamp } else { $stamp + '_FAILED' })
        Rename-Item -LiteralPath $setDir -NewName $finalName
        $finalDir = Join-Path (Split-Path -Parent $setDir) $finalName
    } catch {
        $ok = $false; Add-Error "仕上げ処理: $($_.Exception.Message)"
    }
}

if ($ok) {
    try {
        # 月次：その月の最初の成功分を monthly\ にコピー
        $monthlyRoot = Join-Path $C.NasRoot 'monthly'
        New-Item -ItemType Directory -Path $monthlyRoot -Force | Out-Null
        $month = $stamp.Substring(0, 6)
        if (-not (Get-ChildItem -LiteralPath $monthlyRoot -Directory | Where-Object { $_.Name -like "$month*" -and $_.Name -notlike '*.partial' })) {
            Write-Log "月次バックアップとして保存: monthly\$stamp"
            $tmp = Join-Path $monthlyRoot ($stamp + '.partial')
            Invoke-Robocopy -Source $finalDir -Destination $tmp | Out-Null
            Rename-Item -LiteralPath $tmp -NewName $stamp
        }

        # 世代の削除
        $sets = Get-BackupSets -NasRoot $C.NasRoot
        $old = @($sets | Where-Object { $_.Kind -eq 'daily' } | Select-Object -Skip $C.DailyKeep) +
               @($sets | Where-Object { $_.Kind -eq 'monthly' } | Select-Object -Skip $C.MonthlyKeep)
        foreach ($s in $old) { Write-Log "古い世代を削除: $($s.Kind)\$($s.Name)"; Remove-DirectoryRobust -Path $s.Path }

        Set-Content -LiteralPath (Join-Path $C.NasRoot 'LAST_SUCCESS.txt') -Value "$stamp $env:COMPUTERNAME" -Encoding UTF8
    } catch { Add-Warning "世代管理: $($_.Exception.Message)" }
}

# 失敗フォルダ・中断フォルダの掃除
try {
    foreach ($kind in 'daily', 'monthly') {
        $dir = Join-Path $C.NasRoot $kind
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -Directory | Where-Object {
            ($_.Name -like '*_FAILED' -and $_.LastWriteTime -lt (Get-Date).AddDays(-$C.FailedKeepDays)) -or
            ($_.Name -like '*.partial' -and $_.LastWriteTime -lt (Get-Date).AddDays(-1))
        } | ForEach-Object { Write-Log "失敗・中断フォルダを削除: $kind\$($_.Name)"; Remove-DirectoryRobust -Path $_.FullName }
    }
} catch { Add-Warning "掃除: $($_.Exception.Message)" }

# ローカルログの掃除
Get-ChildItem -LiteralPath $C.LocalLogDir -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$C.LocalLogKeepDays) } | Remove-Item -Force -ErrorAction SilentlyContinue

# ---- 結果の通知 ----------------------------------------------------------
$elapsed = [int]((Get-Date) - $startedAt).TotalMinutes
if ($ok) { Write-Log "バックアップ成功 $stamp（$elapsed 分、警告 $($warnings.Count) 件）" }
else     { Write-Log "バックアップ失敗 $stamp（エラー $($errors.Count) 件）" 'ERROR' }

if (-not $ok -or $warnings.Count -gt 0) {
    $kindLabel = $(if ($ok) { 'WARN' } else { 'FAILED' })
    $body = @(
        "サーバー $env:COMPUTERNAME のバックアップで問題が発生しました（$stamp）"
        "結果: $kindLabel"
        ''
        'エラー:'; $(if ($errors.Count) { $errors | ForEach-Object { "  - $_" } } else { '  （なし）' })
        '警告:';   $(if ($warnings.Count) { $warnings | ForEach-Object { "  - $_" } } else { '  （なし）' })
        ''
        "ログ: $script:LogFile"
        '確認・対応したらこのファイルを削除してください。'
    )
    $alertName = "BACKUP_{0}_{1}.txt" -f $kindLabel, $stamp
    foreach ($d in @($C.AlertDesktopDir, $C.NasRoot)) {
        try { if ($d -and (Test-Path -LiteralPath $d)) { Set-Content -LiteralPath (Join-Path $d $alertName) -Value $body -Encoding UTF8 } } catch { }
    }
}

try {
    if ([System.Diagnostics.EventLog]::SourceExists($C.EventSource)) {
        $etype = $(if (-not $ok) { 'Error' } elseif ($warnings.Count -gt 0) { 'Warning' } else { 'Information' })
        $eid = $(if (-not $ok) { 1001 } elseif ($warnings.Count -gt 0) { 1002 } else { 1000 })
        Write-EventLog -LogName Application -Source $C.EventSource -EntryType $etype -EventId $eid `
            -Message ("バックアップ {0}: {1}`n{2}" -f $manifest.Status, $stamp, ((@($errors) + @($warnings)) -join "`n"))
    }
} catch { }

# ログを NAS にも残す
try {
    $nasLogDir = Join-Path $C.NasRoot 'logs'
    if (Test-Path -LiteralPath $C.NasRoot) {
        New-Item -ItemType Directory -Path $nasLogDir -Force | Out-Null
        Copy-Item -LiteralPath $script:LogFile -Destination $nasLogDir -Force
        if ($finalDir) { Copy-Item -LiteralPath $script:LogFile -Destination (Join-Path $finalDir 'backup.log') -Force }
        Get-ChildItem -LiteralPath $nasLogDir -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$C.LocalLogKeepDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
} catch { }

$lock.Dispose()
if ($ok) { exit 0 } else { exit 1 }
