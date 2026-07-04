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
          fullname: :boolean,
          type: :string,
          t: :boolean,
          r: :boolean
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
        Config.load(opts[:config])
        {:ok, _pid} = Output.start_link(verbose: opts[:verbose] || false)
        {:ok, _pid} = ThesisMonitor.TokenManager.start_link()
        Commands.Status.run([], opts)
    end
  end

  defp process({opts, [command | args]}) do
    Config.load(opts[:config])

    # OutputプロセスとTokenManagerを開始
    {:ok, _pid} = Output.start_link(verbose: opts[:verbose] || false)
    {:ok, _pid} = ThesisMonitor.TokenManager.start_link()

    case command do
      "status" ->
        Commands.Status.run(args, opts)

      "activity" ->
        Commands.Activity.run(args, opts)

      "pr-stats" ->
        Commands.PullRequestStats.run(args, opts)

      "check" ->
        Commands.Check.run(args, opts)

      "bulk" ->
        Commands.Bulk.run(args, opts)

      "search" ->
        Commands.Search.run(args, opts)

      _ ->
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
      --show-status       リポジトリステータス（設定完了状況）を表示
      --fullname          名前の長い場合も切り詰めずに全文表示
      --type              リポジトリタイプで絞り込み (thesis, wr, ise-report, all)
      -t                  最終更新時刻順でソート
      -r                  ソート順を逆順にする

    Examples:
      thesis-monitor status
      thesis-monitor status --show-protection
      thesis-monitor status --show-status
      thesis-monitor status --fullname
      thesis-monitor status --type thesis
      thesis-monitor status --type wr
      thesis-monitor status -t              # 時刻順でソート
      thesis-monitor status -t -r           # 時刻順の逆順（古い順）
      thesis-monitor status -r              # 学籍番号の逆順
      thesis-monitor activity --format json
      thesis-monitor pr-stats --verbose
      thesis-monitor search k92rs004
      thesis-monitor search "田中" --format json

    Configuration:
      設定ファイル: ~/.thesis-monitor.yml または ./config/thesis-monitor.yml
      設定例: config/thesis-monitor.yml.example を参照
      
    Required Configuration:
      data_dir: thesis-student-registry/data ディレクトリへの絶対パス
    """)
  end

  defp show_version do
    IO.puts("Thesis Monitor v#{@version}")
  end
end
