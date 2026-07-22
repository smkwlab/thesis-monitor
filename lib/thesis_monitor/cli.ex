defmodule ThesisMonitor.CLI do
  @moduledoc """
  学生論文リポジトリ管理ツールのCLIインターフェース。

  strict パース・help 短絡・コマンド別オプション検証は `ToolKit.CLI.Parser` に
  委譲し、サブコマンド省略時は status を実行する。exit code は成功 0 / エラー 1。
  """

  alias ThesisMonitor.{
    Commands,
    Config,
    Output
  }

  alias ThesisMonitor.CLI.Spec
  alias ToolKit.CLI.Exit, as: EngineExit
  alias ToolKit.CLI.Parser, as: EngineParser

  @version Mix.Project.config()[:version]

  @command_modules %{
    "init" => Commands.Init,
    "status" => Commands.Status,
    "activity" => Commands.Activity,
    "pr-stats" => Commands.PullRequestStats,
    "check" => Commands.Check,
    "bulk" => Commands.Bulk,
    "search" => Commands.Search
  }

  def main(args \\ []) do
    args
    |> parse_args()
    |> process()
  rescue
    e in RuntimeError ->
      Output.error(e.message)
      exit_with_code(1)
  end

  @doc false
  def known_commands, do: Map.keys(@command_modules)

  @doc false
  def parse_args(args) do
    case EngineParser.parse(Spec.spec(), args, default_command: "status") do
      {:command, _invoked, _argv, opts} = command ->
        if opts[:version], do: :version, else: command

      other ->
        other
    end
  end

  @doc false
  # ライブラリ内部の debug ログ（req の redirect 等）が CLI 出力に混ざらないよう
  # 既定を warning に絞る。--verbose ではトラブルシュート用に debug を残す
  def configure_logger(opts) do
    Logger.configure(level: if(opts[:verbose], do: :debug, else: :warning))
  end

  defp process(:help) do
    IO.puts(Spec.render_help())
    exit_with_code(0)
  end

  defp process({:help_command, name}) do
    IO.puts(Spec.render_command_help(name))
    exit_with_code(0)
  end

  defp process(:version) do
    IO.puts("Thesis Monitor v#{@version}")
    exit_with_code(0)
  end

  defp process({:error, reason}) do
    Output.error(reason)
    exit_with_code(1)
  end

  defp process({:command, command, args, opts}) do
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
        case module.run(args, opts) do
          {:error, _reason} -> exit_with_code(1)
          _result -> exit_with_code(0)
        end

      :error ->
        Output.error("Unknown command: #{command}")
        IO.puts(Spec.render_help())
        exit_with_code(1)
    end
  end

  # テスト時は System.halt せず throw する（ToolKit.CLI.Exit の test_mode 規約）
  @spec exit_with_code(non_neg_integer()) :: no_return()
  defp exit_with_code(code), do: EngineExit.exit_with_code(:thesis_monitor, code)
end
