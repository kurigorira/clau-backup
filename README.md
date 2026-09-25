# 院内Webサーバー NAS日次バックアップ

電子カルテのネットワーク（インターネット非接続）上で動いている Windows サーバー（Apache24 / PHP / MySQL / SQLite、ドキュメントルート `C:\apache24\htdocs`）を、毎晩院内のNASにバックアップして、障害時に戻せるようにするスクリプト一式です。
追加のソフトは不要です（PowerShell 5.1、タスクスケジューラ、robocopy、mysqldump と、`sqlite3.exe` を1つ置くだけ）。

| 取るもの | 方法 |
|---|---|
| MySQL | DBごとに `mysqldump --single-transaction`（サービスを止めない） |
| SQLite | `sqlite3 .backup`（PHPが書き込み中でも安全）＋ `integrity_check` |
| htdocs、Apacheの設定、php.ini、my.ini、その他のフォルダ | `robocopy` |

世代は日次14＋月次12。失敗したらデスクトップとNASに `BACKUP_FAILED_*.txt` を置きます。前回よりDBやファイルが急に減ったら `BACKUP_WARN_*.txt` を置きます（誤削除・ランサムウェアの早期発見）。

## ファイル

| パス | 内容 |
|---|---|
| `backup/config.ps1` | 設定（NASのパス、対象のDB・フォルダ、世代数）。**（仮）の箇所を書き換える** |
| `backup/backup.ps1` | 日次バックアップ本体 |
| `backup/restore.ps1` | 一覧表示・取り出し・試し復元・上書き復元 |
| `backup/register-task.ps1` | タスクスケジューラへの登録（毎日2:00） |
| `backup/common.ps1` | 共通関数 |
| `backup/mysql-backup.cnf.sample` | MySQLのバックアップ用アカウント設定のサンプル |
| `docs/導入手順.md` | 導入の手順と毎日・毎月の運用 |
| `docs/復元手順書.md` | 障害時の手順（印刷してサーバーの近くに保管する） |
| `docs/要件定義_院内サーバーバックアップ_20260925.md` | 要件定義書（未決事項一覧つき） |

## NASの中身

```
\\NAS01\backup\webserver\
  daily\20260925_020000\        ← 1回分（mysql\ sqlite\ files\ manifest.json backup.log）
  monthly\20260901_020000\      ← 各月の最初の成功分
  logs\                         ← 実行ログ（90日）
  LAST_SUCCESS.txt              ← 最後に成功した日時
  BACKUP_FAILED_*.txt           ← 失敗したときだけ
```

## よく使うコマンド

```powershell
cd C:\backup\scripts
.\backup.ps1                                                    # 手動でバックアップ
.\restore.ps1 -List                                             # 世代の一覧
.\restore.ps1 -Target MySql -Database karte -AsDatabase karte_check   # 別名のDBに試し復元
.\restore.ps1 -Target All                                       # C:\restore\ に取り出す（元の場所は変更しない）
.\restore.ps1 -Backup 20260925_020000 -Target All -Overwrite    # 元の場所に戻す（上書き前の状態は自動で退避）
```
