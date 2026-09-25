# =====================================================================
#  院内Webサーバー 復元
#
#  使い方（管理者の PowerShell で実行。詳しくは docs\復元手順書.md）
#    一覧を見る         : .\restore.ps1 -List
#    中身を確認用に取り出す（元の場所は変更しない。既定で C:\restore\<日時>\ に出る）
#                         .\restore.ps1 -Target All
#    DBを別名で試し復元 : .\restore.ps1 -Target MySql -Database karte -AsDatabase karte_test
#    元の場所に戻す     : .\restore.ps1 -Backup 20260925_020000 -Target All -Overwrite
#
#  -Overwrite を付けたときは、上書き前の状態を C:\backup\pre-restore\ に退避してから戻します。
# =====================================================================
[CmdletBinding()]
param(
    [switch]$List,
    [string]$Backup = 'latest',
    [ValidateSet('MySql', 'Sqlite', 'Files', 'All')][string]$Target,
    [string]$Database,
    [string]$AsDatabase,
    [string]$Item,
    [string]$Destination,
    [switch]$Overwrite,
    [switch]$Force,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.ps1')
)

. (Join-Path $PSScriptRoot 'common.ps1')
. $ConfigPath
$C = $BackupConfig

if (-not (Test-Path -LiteralPath $C.NasRoot)) { throw "NAS に接続できません: $($C.NasRoot)" }
$sets = Get-BackupSets -NasRoot $C.NasRoot

# ---- 一覧 ----------------------------------------------------------------
if ($List -or -not $Target) {
    $sets | ForEach-Object {
        $m = $null; try { $m = Read-Manifest -SetPath $_.Path } catch { }
        [pscustomobject]@{
            種別 = $_.Kind; 名前 = $_.Name
            状態 = $(if ($m) { $m.Status } else { '?' })
            MySQL = $(if ($m) { @($m.MySql).Count } else { '' })
            SQLite = $(if ($m) { @($m.Sqlite).Count } else { '' })
            警告 = $(if ($m) { @($m.Warnings).Count } else { '' })
        }
    } | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    if (-not $Target) { Write-Host '復元するには -Target MySql / Sqlite / Files / All を指定してください。'; }
    exit 0
}

# ---- 復元元の決定と検証 --------------------------------------------------
if ($Backup -eq 'latest') { $set = $sets | Select-Object -First 1 }
else { $set = $sets | Where-Object { $_.Name -eq $Backup } | Select-Object -First 1 }
if (-not $set) { throw "バックアップが見つかりません: $Backup（-List で一覧を確認してください）" }
$m = Read-Manifest -SetPath $set.Path

$runStamp = Get-Date -Format 'yyyyMMdd_HHmmss'
Initialize-Log -Dir $C.LocalLogDir -Prefix 'restore' | Out-Null
Write-Log "復元元: $($set.Kind)\$($set.Name)（取得時のサーバー: $($m.Host)）"

if (-not $Overwrite -and -not $Destination) { $Destination = [System.IO.Path]::Combine('C:\restore', $set.Name) }
$preDir = Join-Path $C.PreRestoreDir $runStamp

# ハッシュ照合（NAS上のバックアップが壊れていないか）
foreach ($e in @($m.MySql) + @($m.Sqlite)) {
    $f = Join-Path $set.Path $e.File
    if (-not (Test-Path -LiteralPath $f)) { throw "バックアップファイルがありません: $f" }
    if ((Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash -ne $e.Sha256) { throw "バックアップファイルが壊れています（ハッシュ不一致）: $f" }
}
Write-Log 'バックアップファイルのハッシュ照合 OK'

# ---- 上書き時の確認 ------------------------------------------------------
if ($Overwrite) {
    $running = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'Apache*' -and $_.Status -eq 'Running' })
    if ($running.Count -gt 0 -and $Target -ne 'MySql') {
        Write-Log "Apache が動いています（$($running.Name -join ', ')）。ファイル・SQLiteの上書き前に停止を推奨します: net stop $($running[0].Name)" 'WARN'
    }
    Write-Host ''
    Write-Host "【注意】$($set.Name) の時点の内容で、元の場所を上書きします（対象: $Target）。" -ForegroundColor Yellow
    Write-Host "        現在の内容は $preDir に退避されます。" -ForegroundColor Yellow
    if (-not $Force) {
        if ((Read-Host '続けるには YES と入力してください') -ne 'YES') { Write-Log '中止しました'; exit 1 }
    }
}

# ---- MySQL ---------------------------------------------------------------
function Restore-MySql {
    $targets = @($m.MySql)
    if ($Database) { $targets = @($targets | Where-Object { $_.Database -eq $Database }) }
    if ($targets.Count -eq 0) { throw "MySQL: 復元対象のDBがありません（-Database の指定を確認）" }
    if ($AsDatabase -and $targets.Count -ne 1) { throw '-AsDatabase を使うときは -Database で1つだけ指定してください' }
    if (-not $AsDatabase -and -not $Overwrite) { throw 'MySQL: 元のDBに戻すには -Overwrite、試し復元には -Database と -AsDatabase を指定してください' }

    $mysql = Get-MySqlExe -Config $C -Name 'mysql.exe'
    $mysqldump = Get-MySqlExe -Config $C -Name 'mysqldump.exe'

    # 管理者の接続情報（ファイルがなければその場で入力し、一時ファイルは最後に消す）
    $cnf = $C.MySqlRestoreDefaultsFile
    $tempCnf = $null
    if (-not (Test-Path -LiteralPath $cnf)) {
        $user = Read-Host 'MySQL 管理者ユーザー名（既定: root）'; if (-not $user) { $user = 'root' }
        $sec = Read-Host "$user のパスワード" -AsSecureString
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        $tempCnf = Join-Path $env:TEMP ('mysql-restore-' + [guid]::NewGuid().ToString('N') + '.cnf')
        $content = "[client]`r`nuser=$user`r`npassword=`"$($plain -replace '\\', '\\' -replace '"', '\"')`"`r`nhost=localhost`r`n"
        [System.IO.File]::WriteAllText($tempCnf, $content, (New-Object System.Text.UTF8Encoding($false)))
        $cnf = $tempCnf
    }
    try {
        foreach ($t in $targets) {
            $name = $(if ($AsDatabase) { $AsDatabase } else { $t.Database })
            if ($name -notmatch '^[A-Za-z0-9_$-]+$') { throw "DB名に使えない文字があります: $name" }
            $exists = @(Invoke-MySqlQuery -Config $C -DefaultsFile $cnf -Query "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$name'").Count -gt 0

            if ($exists) {
                if (-not $Overwrite) { throw "DB '$name' は既にあります。別の名前を -AsDatabase に指定してください" }
                New-Item -ItemType Directory -Path (Join-Path $preDir 'mysql') -Force | Out-Null
                $pre = Join-Path $preDir "mysql\$name.sql"
                Write-Log "復元前の現在のDBを退避: $name -> $pre"
                $r = Invoke-Native -Exe $mysqldump -Arguments @("--defaults-extra-file=$cnf", '--single-transaction', '--routines', '--triggers', '--events',
                    '--hex-blob', '--default-character-set=utf8mb4', "--result-file=$pre", $name)
                if ($r.ExitCode -ne 0) { throw "現在のDBの退避に失敗したため中止します: $($r.Text)" }
                Invoke-MySqlQuery -Config $C -DefaultsFile $cnf -Query "DROP DATABASE ``$name``" | Out-Null
            }
            $charset = $(if ($t.Charset) { $t.Charset } else { 'utf8mb4' })
            $collate = $(if ($t.Collation) { " COLLATE $($t.Collation)" } else { '' })
            Invoke-MySqlQuery -Config $C -DefaultsFile $cnf -Query "CREATE DATABASE ``$name`` CHARACTER SET $charset$collate" | Out-Null

            $file = Join-Path $set.Path $t.File
            Write-Log "MySQL 復元: $($t.Database) -> $name"
            $r = Invoke-Native -Exe $mysql -Arguments @("--defaults-extra-file=$cnf", '--default-character-set=utf8mb4', $name, '-e', ('source ' + ($file -replace '\\', '/')))
            if ($r.ExitCode -ne 0) { throw "MySQL 復元失敗 ($name): $($r.Text)" }

            $tables = Invoke-MySqlQuery -Config $C -DefaultsFile $cnf -Query "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='$name'"
            Write-Log "MySQL 復元完了: $name（テーブル数 $($tables[0])）"
        }
        if ($m.MySqlGrantsFile) { Write-Log "アカウントを作り直す場合は $(Join-Path $set.Path $m.MySqlGrantsFile) を参照してください" }
    } finally {
        if ($tempCnf) { Remove-Item -LiteralPath $tempCnf -Force -ErrorAction SilentlyContinue }
    }
}

# ---- SQLite --------------------------------------------------------------
function Restore-Sqlite {
    foreach ($s in @($m.Sqlite)) {
        $src = Join-Path $set.Path $s.File
        if ($Overwrite) {
            $dest = $s.Source
            if (Test-Path -LiteralPath $dest) {
                New-Item -ItemType Directory -Path (Join-Path $preDir 'sqlite') -Force | Out-Null
                foreach ($suffix in '', '-wal', '-shm', '-journal') {
                    if (Test-Path -LiteralPath ($dest + $suffix)) {
                        Copy-Item -LiteralPath ($dest + $suffix) -Destination (Join-Path $preDir ('sqlite\' + (Split-Path -Leaf $s.File) + $suffix)) -Force
                    }
                }
            }
            # 古い WAL が残っていると復元したDBが壊れるので消す
            foreach ($suffix in '-wal', '-shm', '-journal') { Remove-Item -LiteralPath ($dest + $suffix) -Force -ErrorAction SilentlyContinue }
        } else {
            $dest = Join-Path $Destination $s.File
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
        Copy-Item -LiteralPath $src -Destination $dest -Force
        if ($s.JournalMode -eq 'wal') {
            Invoke-Native -Exe $C.SqliteExe -Arguments @($dest, 'PRAGMA journal_mode=WAL;') | Out-Null
        }
        Write-Log "SQLite 復元: $($s.Source) -> $dest"
    }
}

# ---- ファイル・フォルダ --------------------------------------------------
function Restore-Files {
    $items = @($m.Items)
    if ($Item) { $items = @($items | Where-Object { $_.Name -eq $Item }) }
    if ($items.Count -eq 0) { throw "ファイル: 復元対象がありません（-Item の指定を確認）" }
    foreach ($it in $items) {
        $src = Join-Path $set.Path ('files\' + $it.Name)
        if ($Overwrite) {
            if ($it.Type -eq 'File') {
                $destDir = Split-Path -Parent $it.Path
                if (Test-Path -LiteralPath $it.Path) {
                    Copy-Item-Robust -Source $it.Path -DestinationDir (Join-Path $preDir ('files\' + $it.Name))
                }
                Copy-Item-Robust -Source (Join-Path $src (Split-Path -Leaf $it.Path)) -DestinationDir $destDir
            } else {
                if (Test-Path -LiteralPath $it.Path) {
                    Write-Log "復元前の現在の内容を退避: $($it.Path)"
                    Copy-Item-Robust -Source $it.Path -DestinationDir (Join-Path $preDir ('files\' + $it.Name))
                }
                # バックアップ時点と完全に同じ状態にする（後から増えたファイルは消える。退避済み）
                # バックアップ対象外にしたファイル（*.tmp など）は消さずに残す
                $exclude = @(); if ($it.Exclude) { $exclude = @($it.Exclude) }
                Copy-Item-Robust -Source $src -DestinationDir $it.Path -ExcludeFiles $exclude -Mirror
            }
            Write-Log "ファイル復元: files\$($it.Name) -> $($it.Path)"
        } else {
            $dest = Join-Path $Destination ('files\' + $it.Name)
            Copy-Item-Robust -Source $src -DestinationDir $dest
            Write-Log "ファイル取り出し: files\$($it.Name) -> $dest"
        }
    }
}

# ---- 実行（All はファイル → SQLite → MySQL の順。htdocs 内の SQLite をオンラインバックアップ版で上書きするため） --
try {
    if ($Target -in 'Files', 'All')  { Restore-Files }
    if ($Target -in 'Sqlite', 'All') { Restore-Sqlite }
    if ($Target -in 'MySql', 'All') {
        if ($Target -eq 'All' -and -not $Overwrite) {
            Write-Log 'MySQL のダンプは次の場所にあります（-AsDatabase で試し復元できます）:'
            @($m.MySql) | ForEach-Object { Write-Log ('  ' + (Join-Path $set.Path $_.File)) }
        } else { Restore-MySql }
    }
    Write-Log '復元が完了しました'
    if ($Overwrite) { Write-Log "上書き前の内容: $preDir" }
    elseif ($Target -ne 'MySql') { Write-Log "取り出し先: $Destination" }
} catch {
    Write-Log $_.Exception.Message 'ERROR'
    Write-Log '復元は途中で止まりました。docs\復元手順書.md の「うまくいかないとき」を確認してください。' 'ERROR'
    exit 1
}
