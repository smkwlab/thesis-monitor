# Thesis Monitor

学生論文リポジトリ管理ツール（Elixir escript版）

## 概要

`thesis_monitor`は、多数の学生リポジトリ（週報・レポート・卒業論文など）を
効率的に監視・管理するためのコマンドラインツールです。
従来のシェルスクリプト版を Elixir で再実装し、以下の改善を実現しました：

- **並行処理**: 複数学生の情報を並列取得（最大10倍高速化）
- **型安全**: Dialyzerによる静的型チェック
- **エラー処理**: OTPによる堅牢なエラーハンドリング
- **単一バイナリ**: escriptによる依存関係なしの配布

## インストール

### 前提条件

- Elixir 1.14以上
- Erlang/OTP 25以上

### ビルド方法

```bash
cd thesis_monitor
mix deps.get
mix escript.build
```

ビルドが完了すると、実行可能な`thesis_monitor`バイナリが生成されます。

### システムへのインストール

```bash
# ローカルbinディレクトリにコピー
cp thesis_monitor ~/.local/bin/

# または/usr/local/binにインストール（要sudo）
sudo cp thesis_monitor /usr/local/bin/
```

## 使用方法

### 初期セットアップ

```bash
# 本番セットアップ: ~/.thesis-monitor.yml の生成、registry データリポジトリの
# clone（既存 checkout があればパス設定のみ）、doctor 検証までを一括で行う
thesis-monitor init

# テスト用サンドボックス: thesis-student-registry-test を使い、
# ./thesis-monitor-test.yml と分離キャッシュを生成する
thesis-monitor init --test

# 既存 checkout を使う場合
thesis-monitor init --registry-dir /path/to/thesis-student-registry/data
```

レジストリデータリポジトリ自体の新規作成（bootstrap）は本ツールのスコープ外です。
[registry-manager](https://github.com/smkwlab/registry-manager) の init を使用してください。

### 基本コマンド

```bash
# 全学生リポジトリの状態表示
thesis_monitor status

# 最近7日間の活動表示
thesis_monitor activity

# PR/Issue統計表示
thesis_monitor pr-stats

# ブランチ保護設定確認
thesis_monitor check

# データ同期
thesis_monitor sync
```

### オプション

```bash
# JSON形式で出力
thesis_monitor status --format json

# CSV形式で出力
thesis_monitor status --format csv

# 詳細ログ表示
thesis_monitor status --verbose

# カスタム設定ファイル使用
thesis_monitor status --config ./my-config.yml
```

## 設定

### 設定ファイル

`~/.thesis-monitor.yml`または`./config/thesis-monitor.yml`に設定ファイルを配置できます
（`config/thesis-monitor.yml.example` 参照）。

```yaml
# GitHub設定
github_org: your-org

# レジストリディレクトリ（レジストリデータリポジトリのローカルチェックアウト内の data/）
registry_dir: /path/to/your-student-registry/data
cache_dir: ~/.cache/thesis-monitor

# 学生名取得用CSVファイル（任意）
student_csv: /path/to/students.csv

# パフォーマンス設定
cache_ttl: 1800         # キャッシュ有効期限（秒）
max_concurrency: 10     # 最大並行リクエスト数
timeout: 10000          # APIタイムアウト（ミリ秒）
```

### 環境変数

```bash
# GitHub APIトークン（必須）
export GITHUB_TOKEN=ghp_xxxxxxxxxxxxx
```

### データソース

`registry_dir` には学生リポジトリレジストリ（**private リポジトリ**で管理される
`data/registry.json`。旧名 `repositories.json` も移行期間中は自動で読み込む）の
ローカルチェックアウトを指定します。旧キー `data_dir` も当面は警告付きで
受け付けますが、`registry_dir` への移行を推奨します。
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
├── student.ex          # 学生データ構造体
├── output.ex           # 出力フォーマット
├── data_source.ex      # データソース統合
├── data_source/
│   ├── local.ex        # ローカルファイル読み込み
│   └── github_api.ex   # GitHub API クライアント
└── commands/           # 各コマンドの実装
    ├── status.ex
    ├── activity.ex
    ├── pr_stats.ex
    └── sync.ex
```

### 並行処理

GitHub APIへのリクエストは`Task.async_stream`を使用して並列実行されます：

```elixir
students
|> Task.async_stream(&fetch_repo_info/1,
  ordered: false,
  timeout: 10_000,
  max_concurrency: 10
)
```

## 開発

### テスト実行

```bash
mix test
```

### 型チェック

```bash
mix dialyzer
```

### コード品質チェック

```bash
mix credo
```

## 移行ガイド

### シェルスクリプト版からの移行

```bash
# 旧コマンド
./thesis-repo-manager.sh status

# 新コマンド
thesis_monitor status
```

コマンド構造は互換性を保っているため、既存のワークフローを変更する必要はありません。

## トラブルシューティング

### GitHub API認証エラー

```bash
# トークンが設定されているか確認
echo $GITHUB_TOKEN

# 正しいトークンを設定
export GITHUB_TOKEN=ghp_xxxxxxxxxxxxx
```

### レート制限エラー

```bash
# キャッシュを有効にして実行
thesis_monitor status --cache
```

## ライセンス

MIT License