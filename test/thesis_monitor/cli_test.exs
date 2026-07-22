# init コマンドは名前付き Output Agent を起動するため、他の async テストと
# プロセス名が衝突しないよう同期実行する
defmodule ThesisMonitor.CLITest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias ThesisMonitor.CLI
  alias ThesisMonitor.CLI.Spec, as: CLISpec

  describe "CLI module" do
    test "module exists and has main function" do
      # main/0 and main/1 are exported due to default arguments
      functions = CLI.__info__(:functions)
      assert {:main, 0} in functions
      assert {:main, 1} in functions
    end

    test "handles help flag and exits 0" do
      output =
        capture_io(fn ->
          assert catch_throw(CLI.main(["--help"])) == {:cli_test_exit, 0}
        end)

      assert output =~ "thesis-monitor"
      assert output =~ "使用方法"
    end

    test "renders per-command help" do
      output =
        capture_io(fn ->
          assert catch_throw(CLI.main(["status", "--help"])) == {:cli_test_exit, 0}
        end)

      assert output =~ "thesis-monitor status"
      assert output =~ "--show-protection"
      refute output =~ "--test"
    end

    test "handles version flag and exits 0" do
      output =
        capture_io(fn ->
          assert catch_throw(CLI.main(["--version"])) == {:cli_test_exit, 0}
        end)

      assert output =~ "Thesis Monitor v"
    end

    test "rejects unknown options (strict parsing)" do
      output =
        capture_io(:stderr, fn ->
          assert catch_throw(CLI.main(["-f", "json"])) == {:cli_test_exit, 1}
        end)

      assert output =~ "不明なオプション"
    end

    test "rejects options that do not belong to the command" do
      output =
        capture_io(:stderr, fn ->
          assert catch_throw(CLI.main(["check", "--format", "json"])) == {:cli_test_exit, 1}
        end)

      assert output =~ "--format"
    end

    test "rejects invalid enum values" do
      output =
        capture_io(:stderr, fn ->
          assert catch_throw(CLI.main(["status", "--type", "bogus"])) == {:cli_test_exit, 1}
        end)

      assert output =~ "bogus"
    end

    test "configure_logger defaults to warning level" do
      original = Logger.level()
      on_exit(fn -> Logger.configure(level: original) end)

      CLI.configure_logger([])

      assert Logger.level() == :warning
    end

    test "configure_logger keeps debug level with verbose" do
      original = Logger.level()
      on_exit(fn -> Logger.configure(level: original) end)

      CLI.configure_logger(verbose: true)

      assert Logger.level() == :debug
    end

    test "module can be loaded" do
      assert Code.ensure_loaded?(CLI)
    end
  end

  describe "spec integrity" do
    test "every dispatch command has a spec entry and vice versa" do
      known = MapSet.new(CLI.known_commands())

      for name <- CLI.known_commands() do
        assert CLISpec.find_command(name), "no spec for command #{name}"
      end

      for command <- CLISpec.commands() do
        assert MapSet.member?(known, command.name),
               "spec command #{command.name} is not dispatchable"
      end
    end

    test "global options are allowed for every command" do
      for command <- CLISpec.commands() do
        allowed = CLISpec.allowed_for(command.name)

        for global <- [:help, :verbose, :config, :version] do
          assert MapSet.member?(allowed, global)
        end
      end
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

      output =
        capture_io(:stderr, fn ->
          # --force なしなので既存 config を検出して停止する（gh は呼ばない）→ exit 1
          assert catch_throw(CLI.main(["init", "--config", config_path])) ==
                   {:cli_test_exit, 1}
        end)

      assert output =~ "already exists"
    end
  end
end
