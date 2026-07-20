defmodule ThesisMonitor.CLI do
  @moduledoc """
  学生論文リポジトリ管理ツールのCLIインターフェース
  """

  alias ThesisMonitor.{
    Commands,
    Config,
    Output
  }

  @version Mix.Project.config()[:version]

  def main(args \\ []) do
    args
    |> parse_args()
    |> process()
  rescue
    e in RuntimeError ->
      Output.error(e.message)
      System.halt(1)
  end

  @doc false
  # ライブラリ内部の debug ログ（req の redirect 等）が CLI 出力に混ざらないよう
  # 既定を warning に絞る。--verbose ではトラブルシュート用に debug を残す
  def configure_logger(opts) do
    Logger.configure(level: if(opts[:verbose], do: :debug, else: :warning))
  end

  defp parse_args(args) do
    {opts, cmd_args, _} =
      OptionParser.parse(args,
        switches: [
          help: :boolean,
          version: :boolean,
          config: :string,
          format: :string,
          verbose: :boolean,
          show_protection: :boolean,
          show_status: :boolean,
          pending_reviews: :boolean,
          fullname: :boolean,
          no_cache: :boolean,
          show_archived: :boolean,
          type: :string,
          t: :boolean,
          r: :boolean,
          # init 用
          test: :boolean,
          org: :string,
          registry_repo: :string,
          force: :boolean
        ],
        aliases: [
          h: :help,
          v: :version,
          c: :config,
          f: :format,
          t: :t,
          r: :r
        ]
      )

    {opts, cmd_args}
  end

  defp process({opts, []}) do
    cond do
      opts[:help] ->
        show_help()

      opts[:version] ->
        show_version()

      true ->
        # デフォルトはstatusコマンドを実行
        configure_logger(opts)
        Config.load(opts[:config])
        Config.apply_cli_overrides(opts)
        {:ok, _pid} = Output.start_link(verbose: opts[:verbose] || false)
        {:ok, _pid} = ThesisMonitor.TokenManager.start_link()
        Commands.Status.run([], opts)
    end
  end

  @command_modules %{
    "init" => Commands.Init,
    "status" => Commands.Status,
    "activity" => Commands.Activity,
    "pr-stats" => Commands.PullRequestStats,
    "check" => Commands.Check,
    "bulk" => Commands.Bulk,
    "search" => Commands.Search
  }

  defp process({opts, [command | args]}) do
    configure_logger(opts)

    # init は設定ファイルを生成する側なので読み込まない
    # （既存 config の legacy キー警告などが init 中に混ざるのを避ける）
    unless command == "init" do
      Config.load(opts[:config])
      Config.apply_cli_overrides(opts)
    end

    # Output は全コマンドで使う
    {:ok, _pid} = Output.start_link(verbose: opts[:verbose] || false)

    # init は gh CLI 経由で完結し token も不要。加えて init では Config を
    # 読み込まず Config Agent が起動していないため、ここで TokenManager を
    # 起動すると Config.get の GenServer.call が exit してクラッシュする。
    unless command == "init" do
      {:ok, _pid} = ThesisMonitor.TokenManager.start_link()
    end

    case Map.fetch(@command_modules, command) do
      {:ok, module} ->
        module.run(args, opts)

      :error ->
        Output.error("Unknown command: #{command}")
        show_help()
        System.halt(1)
    end
  end

  defp show_help do
    IO.puts("""
    Thesis Monitor - 学生論文リポジトリ管理ツール

    Usage: thesis-monitor [command] [options]

    Commands:
      init        セットアップ（設定ファイル生成・doctor 検証）
      status      全学生リポジトリの状態を表示
      activity    最近のコミット活動を表示（過去7日間）
      pr-stats    PR/Issue統計を表示
      check       ブランチ保護設定を確認
      bulk        一括ブランチ保護設定
      search      学生情報を検索・表示
      help        このヘルプを表示
      version     バージョン情報を表示

    Options:
      -h, --help          コマンドのヘルプを表示
      -v, --version       バージョン情報を表示
      -c, --config        設定ファイルのパス
      -f, --format        出力形式 (table, json, csv)
      --verbose           詳細ログを表示
      --show-protection   ブランチ保護状況を表示
      --show-status       リポジトリの存在状態（Active / Not Found）を表示
      --pending-reviews   教員の返信待ち PR 件数を表示（API 追加取得のためオプトイン）
      --fullname          名前の長い場合も切り詰めずに全文表示
      --no-cache          キャッシュを読まず常に最新を取得（レジストリを書き換えた直後の確認用）
      --show-archived     archive 済みリポジトリも一覧に表示（既定は現役のみ）
      --type              リポジトリタイプで絞り込み (thesis, wr, ise-report, all)
      -t                  最終更新時刻順でソート
      -r                  ソート順を逆順にする

    Init options:
      --test              テスト用サンドボックス設定を生成（thesis-student-registry-test を使用）
      --org               GitHub organization（デフォルト: smkwlab）
      --registry-repo     レジストリデータリポジトリ（owner/repo 形式。
                          デフォルト: <org>/thesis-student-registry）
      --force             既存の設定ファイルを上書き

    Examples:
      thesis-monitor init                 # 本番セットアップ（~/.config/thesis-monitor/config.yml 生成）
      thesis-monitor init --test          # テスト用サンドボックス（./thesis-monitor-test.yml 生成）
      thesis-monitor status
      thesis-monitor status --show-protection
      thesis-monitor status --show-status
      thesis-monitor status --fullname
      thesis-monitor status --type thesis
      thesis-monitor status --type wr
      thesis-monitor status --type ise --pending-reviews   # 教員の返信待ち PR 件数
      thesis-monitor status -t              # 時刻順でソート
      thesis-monitor status -t -r           # 時刻順の逆順（古い順）
      thesis-monitor status -r              # 学籍番号の逆順
      thesis-monitor activity --format json
      thesis-monitor pr-stats --verbose
      thesis-monitor search k92rs004
      thesis-monitor search "田中" --format json

    Configuration:
      設定ファイル: ~/.config/thesis-monitor/config.yml または ./config/thesis-monitor.yml
      設定例: config/thesis-monitor.yml.example を参照
      
    Configuration keys:
      registry_repo: レジストリデータリポジトリ（owner/repo）。未設定時は
                     <github_org>/thesis-student-registry を規約として使用
      csv_path:      学生名簿 CSV のパス（任意。ローカル管理。未設定時は
                     ~/.config/<github_org>/students.csv を規約として参照）
    """)
  end

  defp show_version do
    IO.puts("Thesis Monitor v#{@version}")
  end
end
