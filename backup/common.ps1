# =====================================================================
#  backup.ps1 / restore.ps1 共通関数
#  Windows PowerShell 5.1 で動くように書いています（PowerShell 7 専用の構文は使わない）
# =====================================================================

$ErrorActionPreference = 'Stop'

$script:LogFile = $null

function Initialize-Log {
    param([string]$Dir, [string]$Prefix)
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $script:LogFile = Join-Path $Dir ('{0}_{1}.log' -f $Prefix, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    return $script:LogFile
}

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
}

function Assert-Tool {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label が見つかりません: $Path" }
}

# robocopy は終了コード 0-7 が成功、8 以上が失敗
function Invoke-Robocopy {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$Files = @(),
        [string[]]$ExcludeFiles = @(),
        [switch]$Mirror
    )
    $rcArgs = @($Source, $Destination) + $Files
    if ($Mirror) { $rcArgs += '/MIR' } else { $rcArgs += '/E' }
    $rcArgs += @('/COPY:DAT', '/DCOPY:T', '/R:2', '/W:5', '/XJ', '/NP', '/NDL', '/NFL', '/FFT')
    if ($ExcludeFiles.Count -gt 0) { $rcArgs += '/XF'; $rcArgs += $ExcludeFiles }
    if ($script:LogFile) { $rcArgs += ('/UNILOG+:' + $script:LogFile + '.robocopy.txt') }
    $code = (Invoke-Native -Exe 'robocopy.exe' -Arguments $rcArgs).ExitCode
    if ($code -ge 8) { throw "robocopy 失敗 (終了コード $code): $Source -> $Destination" }
    return $code
}

# ファイルでもフォルダでもコピーする（ファイルは同名でコピー先フォルダの下に置く）
function Copy-Item-Robust {
    param([string]$Source, [string]$DestinationDir, [string[]]$ExcludeFiles = @(), [switch]$Mirror)
    if (Test-Path -LiteralPath $Source -PathType Leaf) {
        $parent = Split-Path -Parent $Source
        $leaf = Split-Path -Leaf $Source
        Invoke-Robocopy -Source $parent -Destination $DestinationDir -Files @($leaf) | Out-Null
    } else {
        Invoke-Robocopy -Source $Source -Destination $DestinationDir -ExcludeFiles $ExcludeFiles -Mirror:$Mirror | Out-Null
    }
}

# SQLiteファイルかどうかを先頭16バイト "SQLite format 3\0" で判定
function Test-SqliteFile {
    param([string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $buf = New-Object byte[] 16
            if ($fs.Read($buf, 0, 16) -lt 16) { return $false }
            return ([System.Text.Encoding]::ASCII.GetString($buf, 0, 15) -eq 'SQLite format 3')
        } finally { $fs.Dispose() }
    } catch { return $false }
}

# 元のフルパスから、バックアップ先で衝突しないファイル名を作る
#   C:\apache24\htdocs\app\data.db -> C_apache24_htdocs_app_data.db
function ConvertTo-SafeName {
    param([string]$Path)
    return (($Path -replace '[:\\/ ]+', '_') -replace '^_+', '')
}

# sqlite3 のドットコマンドに渡すパス（\ を / に変え、' をエスケープ）
function ConvertTo-SqlitePath {
    param([string]$Path)
    return (($Path -replace '\\', '/') -replace "'", "''")
}

# 外部コマンドを実行して出力と終了コードを返す。
# Windows PowerShell 5.1 は ErrorActionPreference=Stop のとき 2>&1 の標準エラー1行目で止まってしまうため、ここだけ Continue にする
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $out = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out; Text = ($out -join ' ') }
}

function Get-MySqlExe {
    param([hashtable]$Config, [string]$Name)
    $exe = Join-Path $Config.MySqlBinDir $Name
    Assert-Tool -Path $exe -Label $Name
    return $exe
}

# mysql クライアントでクエリを実行し、タブ区切りの行を返す
function Invoke-MySqlQuery {
    param([hashtable]$Config, [string]$Query, [string]$DefaultsFile)
    $mysql = Get-MySqlExe -Config $Config -Name 'mysql.exe'
    $r = Invoke-Native -Exe $mysql -Arguments @("--defaults-extra-file=$DefaultsFile", '--batch', '--skip-column-names', '--default-character-set=utf8mb4', '-e', $Query)
    if ($r.ExitCode -ne 0) { throw "mysql 実行失敗: $($r.Text)" }
    return @($r.Output | Where-Object { $_ -ne '' })
}

# バックアップ一覧（成功したもののみ、新しい順）
function Get-BackupSets {
    param([string]$NasRoot)
    $sets = @()
    foreach ($kind in @('daily', 'monthly')) {
        $dir = Join-Path $NasRoot $kind
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Get-ChildItem -LiteralPath $dir -Directory | Where-Object { $_.Name -match '^\d{8}_\d{6}$' } | ForEach-Object {
            $sets += [pscustomobject]@{ Kind = $kind; Name = $_.Name; Path = $_.FullName }
        }
    }
    return @($sets | Sort-Object -Property Name -Descending)
}

function Read-Manifest {
    param([string]$SetPath)
    $file = Join-Path $SetPath 'manifest.json'
    if (-not (Test-Path -LiteralPath $file)) { throw "manifest.json がありません: $SetPath" }
    return (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json)
}

# 深い階層（260文字超）でも消せるよう、空フォルダで /MIR してから削除する
function Remove-DirectoryRobust {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $empty = Join-Path ([System.IO.Path]::GetTempPath()) ('empty_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $empty -Force | Out-Null
    try {
        Invoke-Native -Exe 'robocopy.exe' -Arguments @($empty, $Path, '/MIR', '/R:1', '/W:1', '/NP', '/NDL', '/NFL', '/NJH', '/NJS') | Out-Null
        Remove-Item -LiteralPath $Path -Recurse -Force
    } finally {
        Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
    }
}
