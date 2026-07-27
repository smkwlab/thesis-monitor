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
      # status はコマンド一覧から消え、list（ls）に置き換わっている
      assert output =~ "thesis-monitor list"
      # 旧 status コマンドの例（thesis-monitor status ...）は残っていない
      refute output =~ "thesis-monitor status"
    end

    test "renders per-command help" do
      output =
        capture_io(fn ->
          assert catch_throw(CLI.main(["list", "--help"])) == {:cli_test_exit, 0}
        end)

      assert output =~ "thesis-monitor list"
      assert output =~ "--show-protection"
      refute output =~ "--test"
    end

    test "renders per-command help via the ls alias" do
      output =
        capture_io(fn ->
          assert catch_throw(CLI.main(["ls", "--help"])) == {:cli_test_exit, 0}
        end)

      # エイリアスでも正準名 list の help に落ちる
      assert output =~ "thesis-monitor list"
      assert output =~ "--show-protection"
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
          assert catch_throw(CLI.main(["list", "--type", "bogus"])) == {:cli_test_exit, 1}
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

  describe "command resolution" do
    test "no subcommand defaults to list" do
      assert {:command, "list", [], _opts} = CLI.parse_args([])
    end

    test "ls is parsed as the list command" do
      # parser は入力名（エイリアス）をそのまま返す。正準化は dispatch 側の責務
      assert {:command, "ls", [], _opts} = CLI.parse_args(["ls"])
    end

    test "status is no longer a known command" do
      refute "status" in CLI.known_commands()
      assert "list" in CLI.known_commands()
      assert CLISpec.find_command("status") == nil
    end

    test "-a is accepted as the short form of --show-archived" do
      assert {:command, "list", [], opts} = CLI.parse_args(["list", "-a"])
      assert opts[:show_archived] == true
    end

    test "-T is accepted as the short form of --type" do
      assert {:command, "list", [], opts} = CLI.parse_args(["list", "-T", "thesis"])
      assert opts[:type] == "thesis"
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

    test "pr-stats accepts the pr-status parity options (issue #59)" do
      allowed = CLISpec.allowed_for("pr-stats")

      for opt <- [:type, :state, :review_requested, :sort, :reverse, :format, :no_cache] do
        assert MapSet.member?(allowed, opt), "pr-stats should allow --#{opt}"
      end
    end

    test "pr-stats --help lists the new options" do
      help = CLISpec.render_command_help("pr-stats")
      assert help =~ "--state"
      assert help =~ "--review-requested"
      assert help =~ "--sort"
    end

    test "pr-stats rejects invalid --state and --sort enum values" do
      output =
        capture_io(:stderr, fn ->
          assert catch_throw(CLI.main(["pr-stats", "--state", "bogus"])) == {:cli_test_exit, 1}
        end)

      assert output =~ "bogus"

      output =
        capture_io(:stderr, fn ->
          assert catch_throw(CLI.main(["pr-stats", "--sort", "nope"])) == {:cli_test_exit, 1}
        end)

      assert output =~ "nope"
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
