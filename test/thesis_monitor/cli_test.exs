# init コマンドは名前付き Output Agent を起動するため、他の async テストと
# プロセス名が衝突しないよう同期実行する
defmodule ThesisMonitor.CLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  describe "CLI module" do
    test "module exists and has main function" do
      # main/0 and main/1 are exported due to default arguments
      functions = ThesisMonitor.CLI.__info__(:functions)
      assert {:main, 0} in functions
      assert {:main, 1} in functions
    end

    test "handles help flag" do
      output =
        capture_io(fn ->
          ThesisMonitor.CLI.main(["--help"])
        end)

      assert output =~ "Thesis Monitor"
      assert output =~ "Usage:"
    end

    test "handles version flag" do
      output =
        capture_io(fn ->
          ThesisMonitor.CLI.main(["--version"])
        end)

      assert output =~ "Thesis Monitor v"
    end

    test "configure_logger defaults to warning level" do
      original = Logger.level()
      on_exit(fn -> Logger.configure(level: original) end)

      ThesisMonitor.CLI.configure_logger([])

      assert Logger.level() == :warning
    end

    test "configure_logger keeps debug level with verbose" do
      original = Logger.level()
      on_exit(fn -> Logger.configure(level: original) end)

      ThesisMonitor.CLI.configure_logger(verbose: true)

      assert Logger.level() == :debug
    end

    test "module can be loaded" do
      assert Code.ensure_loaded?(ThesisMonitor.CLI)
    end
  end

  describe "init command" do
    # 回帰(#9): init は Config を読み込まない側なので Config Agent が起動していない。
    # そのまま TokenManager を起動すると TokenManager が Config.get を呼び、
    # GenServer.call が "no process" で exit してクラッシュしていた。
    @tag :tmp_dir
    test "runs without a Config agent and stops on existing config", %{tmp_dir: tmp_dir} do
      config_path = Path.join(tmp_dir, "existing.yml")
      File.write!(config_path, "github_org: smkwlab\n")

      parent = self()

      output =
        capture_io(:stderr, fn ->
          send(parent, {:result, ThesisMonitor.CLI.main(["init", "--config", config_path])})
        end)

      # --force なしなので既存 config を検出して停止する（gh は呼ばない）
      assert_received {:result, {:error, :config_exists}}
      assert output =~ "already exists"
    end
  end
end
