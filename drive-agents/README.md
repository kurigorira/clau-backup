# Google ドライブ連携エージェント一覧

各エージェントは Google ドライブの用途別フォルダ1つに紐づいています。

| エージェント | 担当フォルダ | フォルダID |
|---|---|---|
| `drive-work` 仕事エージェント（長崎北徳洲会病院） | [01_仕事_長崎北徳洲会病院](https://drive.google.com/drive/folders/1hLxwNsygDAUalwi6oIWo5XZCLniyMr3q) | `1hLxwNsygDAUalwi6oIWo5XZCLniyMr3q` |
| `drive-pcgow` 事業エージェント（PC GOW） | [02_事業_PC GOW](https://drive.google.com/drive/folders/1Egw3ISEkDJzfsdtN_JS-kRWKcInnJxYd) | `1Egw3ISEkDJzfsdtN_JS-kRWKcInnJxYd` |
| `drive-kakei` 家計エージェント | [03_家計・お金・住まい](https://drive.google.com/drive/folders/1rnlg2g8BOGAtqziys01jqqRQif5jm2rf) | `1rnlg2g8BOGAtqziys01jqqRQif5jm2rf` |
| `drive-family` 家族・教育エージェント | [04_家族・教育](https://drive.google.com/drive/folders/1hWSq9zdrswBWQgaAl1rCSUPV973-1lTu) | `1hWSq9zdrswBWQgaAl1rCSUPV973-1lTu` |
| `drive-jichikai` 自治会エージェント（シーサイド日並） | [05_地域・自治会](https://drive.google.com/drive/folders/1zAKwUD25Ysl4yUrOEL5VhCviVfXVXx-6) | `1zAKwUD25Ysl4yUrOEL5VhCviVfXVXx-6` |
| `drive-music` 音楽エージェント | [06_趣味_音楽](https://drive.google.com/drive/folders/1D1qi4jKkXx829JNJLlUx9H6LOBg6l0XQ) | `1D1qi4jKkXx829JNJLlUx9H6LOBg6l0XQ` |
| `drive-personal` 個人記録エージェント | [07_個人記録・メモ](https://drive.google.com/drive/folders/1FBYXl1My0-nIf8LujihCxTb91NnQaSst) | `1FBYXl1My0-nIf8LujihCxTb91NnQaSst` |
| `drive-learning` 学習・AIエージェント | [08_学習・AI・技術](https://drive.google.com/drive/folders/1fBMtyz2jgHPe9FGfw5bhFs3EUfJtgdxI) | `1fBMtyz2jgHPe9FGfw5bhFs3EUfJtgdxI` |
| `drive-photos` 写真・動画アーカイブエージェント | [09_写真・動画アーカイブ](https://drive.google.com/drive/folders/1f3uuuzOwq2GgN9h-kaGitAXiEMM7bmsh) | `1f3uuuzOwq2GgN9h-kaGitAXiEMM7bmsh` |
| `drive-kitatoku` 長崎北徳洲会病院エージェント（ユーザー作成・本リポジトリ外） | [10_長崎北徳洲会病院](https://drive.google.com/drive/folders/1IpO8MsvoSVi5wW3KR-r51agEGR6OFURY) | `1IpO8MsvoSVi5wW3KR-r51agEGR6OFURY` |
| `drive-apps` アプリ・ツール開発エージェント | [11_アプリ・ツール開発](https://drive.google.com/drive/folders/1Z-XOKXI7vNu5IiRx2uHNTbH-mJVmKxk3) | `1Z-XOKXI7vNu5IiRx2uHNTbH-mJVmKxk3` |

## 使い方

| 使う場所 | 手順 |
|---|---|
| Claude（チャット）/ Cowork | claude.ai の「設定 › 機能 › スキル」で `zips/` 内の zip をアップロードして有効化する。以後「仕事エージェントで◯◯を探して」のように頼む。 |
| Claude プロジェクト | プロジェクトを作り、該当フォルダの `SKILL.md` の本文を「プロジェクトの指示」に貼る。ナレッジにはドライブの該当フォルダのファイルを追加する。 |
| Claude Code | `drive-<名前>/` フォルダを `~/.claude/skills/` か、リポジトリの `.claude/skills/` にコピーする。 |

## 整理の記録（2026-10-08）
- 用途別 9 フォルダ（01〜09）を作り、その中を種類別（ドキュメント／スライド／スプレッドシート／PDF など）に分けた。
- 削除（ゴミ箱、30日間は復元可）：Google Keep 書き出し一式、無線LANドライバ一式（AC1300）、重複ファイル、中身が空のファイル、空になった旧フォルダ。
- 「無題」ファイルのうち中身があったものは削除せず、内容がわかる名前に変更した。
- 「山内さん」フォルダは指示どおりそのまま（他者所有ファイルを含む）。

## 追加整理（2026-10-12）
- マイドライブ直下にあった「C-QUES-GOU.K」（Apps Script）と「C-QUES-NET 回答一覧」（スプレッドシート）を、新フォルダ「11_アプリ・ツール開発 / C-QUES（アンケートアプリ）」へ移動した。ファイルIDは変わらないので、スクリプトとシートのつながりはそのまま。
- 担当スキル `drive-apps` を追加した。
- 「ドライブ整理計画_20261008」を「00_Claudeエージェント設定」へ移動した。
