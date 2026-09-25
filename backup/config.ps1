# =====================================================================
#  院内Webサーバー バックアップ設定
#  （仮）と書いてある値は環境に合わせて書き換えてください。
#  このファイルは backup.ps1 / restore.ps1 から読み込まれます。
# =====================================================================

$BackupConfig = @{

    # ---- 保存先（NAS） ------------------------------------------------
    # バックアップ用の共有フォルダ（UNCパス）。（仮）
    NasRoot            = '\\NAS01\backup\webserver'

    # ---- ローカル作業領域 ----------------------------------------------
    # DBダンプを一時的に作る場所。直近1世代はここにも残るので、NASが壊れたときにも使えます。
    LocalWorkDir       = 'C:\backup\work'
    # ローカルのログ置き場
    LocalLogDir        = 'C:\backup\logs'
    # ローカルログの保存日数
    LocalLogKeepDays   = 90
    # 復元前に現在の状態を退避しておく場所
    PreRestoreDir      = 'C:\backup\pre-restore'

    # ---- 世代管理 ------------------------------------------------------
    DailyKeep          = 14    # 日次バックアップを何世代残すか
    MonthlyKeep        = 12    # 月次（各月の最初に成功したもの）を何世代残すか
    FailedKeepDays     = 14    # 失敗したバックアップフォルダを何日残すか

    # ---- 失敗・警告の通知 ----------------------------------------------
    # 失敗したときに通知ファイルを置くデスクトップ（全ユーザー共通のデスクトップ）
    AlertDesktopDir    = 'C:\Users\Public\Desktop'
    # Windowsイベントログのソース名（register-task.ps1 で登録されます）
    EventSource        = 'WebServerBackup'
    # DBダンプのサイズが前回より何割以上小さくなったら警告するか（0.5 = 半分未満で警告）
    ShrinkWarnRatio    = 0.5

    # ---- MySQL ---------------------------------------------------------
    # MySQLを使っていない場合は $false
    MySqlEnabled       = $true
    # mysqldump.exe / mysql.exe があるフォルダ。（仮）
    MySqlBinDir        = 'C:\mysql\bin'
    # バックアップ用アカウントの接続情報ファイル（mysql-backup.cnf.sample を参考に作成）
    MySqlDefaultsFile  = 'C:\backup\secure\mysql-backup.cnf'
    # 復元に使う管理者アカウントの接続情報ファイル。ファイルがなければ、復元時にrootのパスワードを入力します
    MySqlRestoreDefaultsFile = 'C:\backup\secure\mysql-restore.cnf'
    # バックアップするDB。空 @() なら、システムDB以外のすべてのDB
    MySqlDatabases     = @()
    # 対象外にするDB（MySqlDatabases が空のときだけ有効）
    MySqlExcludeDatabases = @('information_schema', 'performance_schema', 'sys', 'mysql')

    # ---- SQLite --------------------------------------------------------
    SqliteEnabled      = $true
    # sqlite3.exe の場所（https://sqlite.org/download.html の sqlite-tools を院外で入手して配置）（仮）
    SqliteExe          = 'C:\backup\tools\sqlite3.exe'
    # バックアップするSQLiteファイルを明示する場合はここに列挙します
    SqliteFiles        = @(
        # 'C:\apache24\htdocs\app\data\app.sqlite'
    )
    # このフォルダの下にあるSQLiteファイルを自動で探します（ファイルの先頭16バイトで判定）
    SqliteSearchRoots  = @('C:\apache24\htdocs')
    SqliteSearchPatterns = @('*.sqlite', '*.sqlite3', '*.db', '*.db3')

    # ---- ファイル・フォルダ --------------------------------------------
    # Name はバックアップ先でのフォルダ名（英数字）。Path がフォルダでもファイルでも使えます。
    # Exclude はコピーしないファイル名のパターン（任意）
    Items = @(
        @{ Name = 'htdocs';      Path = 'C:\apache24\htdocs'; Exclude = @('*.tmp', 'Thumbs.db') }
        @{ Name = 'apache-conf'; Path = 'C:\apache24\conf' }
        @{ Name = 'php-ini';     Path = 'C:\php\php.ini' }        # （仮）
        @{ Name = 'mysql-ini';   Path = 'C:\mysql\my.ini' }       # （仮）
        # その他の重要フォルダをここに追加してください（仮）
        # @{ Name = 'uploads';   Path = 'D:\uploads' }
    )

    # ---- バージョン記録（新しいサーバーに作り直すときの参考情報。なくても可） ----
    ApacheExe          = 'C:\apache24\bin\httpd.exe'
    PhpExe             = 'C:\php\php.exe'                        # （仮）
}
