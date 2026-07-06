# Thesis Monitor

学生リポジトリ監視ツール（Elixir escript）

## 概要

`thesis-monitor` は、多数の学生リポジトリ（週報・レポート・卒業論文・修士論文・
研究会原稿など）を効率的に監視するためのコマンドラインツールです。
レジストリデータリポジトリ（[registry-manager](https://github.com/smkwlab/registry-manager)
が管理する `data/registry.json`）を GitHub contents API で読み取って索引とし、
各リポジトリの状態・最新 draft ブランチ・ブランチ保護状況を GitHub API から
並列取得します。ローカル checkout は不要です（レジストリの応答は
`cache_dir` に `cache_ttl` 秒キャッシュされます）。

- **並行処理**: 複数学生の情報を並列取得（`Task.async_stream`）
- **型安全**: Dialyzer による静的型チェック
- **単一バイナリ**: escript による依存関係なしの配布

## インストール

### 前提条件

- Elixir 1.14 以上
- Erlang/OTP 25 以上

### ビルド方法

```bash
# リポジトリのルートで
mix deps.get
mix escript.build
```

ビルドが完了すると、実行可能な `thesis-monitor` バイナリが生成されます。

### システムへのインストール

```bash
# ローカル bin ディレクトリにコピー
cp thesis-monitor ~/.local/bin/

# または /usr/local/bin にインストール（要 sudo）
sudo cp thesis-monitor /usr/local/bin/
```

## 使用方法

### 初期セットアップ

```bash
# 本番セットアップ: ~/.thesis-monitor.yml の生成と doctor 検証を行う
# （レジストリは GitHub API で読むため clone は不要）
thesis-monitor init

# テスト用サンドボックス: thesis-student-registry-test を使い、
# ./thesis-monitor-test.yml と分離キャッシュを生成する
thesis-monitor init --test

# ローカル checkout を読む legacy 設定を生成する場合（通常は不要）
thesis-monitor init --registry-dir /path/to/thesis-student-registry/data
```

レジストリデータリポジトリ自体の新規作成（bootstrap）は本ツールのスコープ外です。
[registry-manager](https://github.com/smkwlab/registry-manager) の init を使用してください。

### 基本コマンド

```bash
# 全学生リポジトリの状態表示（最新 draft ブランチ・最終更新）
thesis-monitor status

# 最近7日間の活動表示
thesis-monitor activity

# PR/Issue統計表示
thesis-monitor pr-stats

# ブランチ保護設定確認
thesis-monitor check

# 一括ブランチ保護設定
thesis-monitor bulk

# 学生情報を検索・表示
thesis-monitor search k22rs001
```

### オプション

```bash
# JSON / CSV 形式で出力
thesis-monitor status --format json
thesis-monitor status --format csv

# タイプで絞り込み（thesis = 卒論 + 修論のまとめフィルタ）
thesis-monitor status --type thesis
thesis-monitor status --type latex

# ブランチ保護状況も表示
thesis-monitor status --show-protection

# 詳細ログ表示
thesis-monitor status --verbose

# カスタム設定ファイル使用
thesis-monitor status --config ./my-config.yml
```

## 設定

### 設定ファイル

`~/.thesis-monitor.yml` または `./config/thesis-monitor.yml` に設定ファイルを配置できます
（`config/thesis-monitor.yml.example` 参照。`thesis-monitor init` で自動生成されます）。

```yaml
# GitHub設定
github_org: your-org

# レジストリデータリポジトリ（owner/repo、contents API で読み取り）
# 未設定時は <github_org>/thesis-student-registry を規約として使用
registry_repo: your-org/thesis-student-registry
cache_dir: ~/.cache/thesis-monitor

# 学生名取得用CSVファイル（任意。名簿はローカル管理 — リポジトリ・レジストリに置かない）
# 未設定時は ~/.config/<github_org>/students.csv を規約として参照（存在時のみ）
csv_path: /path/to/students.csv

# パフォーマンス設定
cache_ttl: 1800         # レジストリ/API キャッシュ有効期限（秒）
max_concurrency: 10     # 最大並行リクエスト数
timeout: 10000          # APIタイムアウト（ミリ秒）
```

registry-manager と設定語彙を共有しています（`github_org` / `registry_repo` /
`csv_path`）。旧キー `registry_dir`（ローカル checkout 読み）・`data_dir`・
`student_csv` も当面は警告付きで受け付けます。

### GitHub 認証

トークンは次の優先順位で解決されます: 設定ファイル > 環境変数 `GITHUB_TOKEN` >
GitHub CLI（`gh auth token`）。`gh auth login` 済みの環境では追加設定は不要です。

```bash
# 環境変数で指定する場合
export GITHUB_TOKEN=ghp_xxxxxxxxxxxxx
```

### データソース

`registry_repo` には学生リポジトリレジストリ（**private リポジトリ**で管理される
`data/registry.json`。旧名 `repositories.json` も移行期間中は自動で読み込む）を
`owner/repo` 形式で指定します。private リポジトリのため、使用するトークンに
当該リポジトリの Contents: Read 権限が必要です。旧キー `registry_dir`
（ローカルチェックアウト読み）も当面は警告付きで受け付けますが、
`registry_repo` への移行を推奨します。

`repository_type` の語彙は `sotsuron` / `master` / `wr` / `ise` / `latex` / `other`
です（`latex` = latex-template 派生の研究会原稿等で、卒論・修論と同様に draft
ブランチ追跡の対象。`--type thesis` は `sotsuron` + `master` のまとめフィルタ）。
データ構造の正本仕様は
[registry-manager のデータ構造仕様書](https://github.com/smkwlab/registry-manager/blob/main/docs/data-structure-specification.md)
を参照してください。

**注意**: レジストリデータや名簿 CSV には個人情報が含まれます。
データリポジトリは必ず private にしてください。

## アーキテクチャ

### モジュール構成

```
lib/thesis_monitor/
├── cli.ex              # CLIインターフェース
├── config.ex           # 設定管理
├── cache.ex            # API 応答のファイルキャッシュ
├── student.ex          # 学生データ構造体
├── output.ex           # 出力フォーマット
├── token_manager.ex    # GitHub トークン解決
├── data_source.ex      # データソース統合
├── data_source/
│   ├── registry.ex     # レジストリ読み取り（API / legacy ローカルの解決）
│   ├── local.ex        # ローカルファイル読み込み（legacy checkout・名簿 CSV）
│   └── github_api.ex   # GitHub API クライアント
└── commands/           # 各コマンドの実装
    ├── init.ex
    ├── status.ex
    ├── activity.ex
    ├── pr_stats.ex
    ├── check.ex
    ├── bulk.ex
    └── search.ex
```

### 並行処理

GitHub API へのリクエストは `Task.async_stream` を使用して並列実行されます：

```elixir
students
|> Task.async_stream(&fetch_repo_info/1,
  ordered: false,
  timeout: 10_000,
  max_concurrency: 10
)
```

## 開発

```bash
mix test          # テスト実行
mix dialyzer      # 型チェック
mix credo         # コード品質チェック
```

CI（GitHub Actions）は共有 workflow により format / compile --warnings-as-errors /
credo --strict / テストマトリクス（LTS + latest）/ dialyzer（push 時）を実行します。

## トラブルシューティング

### GitHub API 認証エラー

```bash
# gh CLI の認証状態を確認
gh auth status

# または環境変数のトークンを確認
echo $GITHUB_TOKEN
```

### レート制限エラー

API 結果は `cache_dir` に `cache_ttl` 秒（既定 30 分）キャッシュされます。
大量のリポジトリを頻繁に照会する場合は `max_concurrency` を下げるか、
`cache_ttl` を延ばしてください。

## ライセンス

MIT License
