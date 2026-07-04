defmodule ThesisMonitor.CLITest do
  use ExUnit.Case, async: true
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

    test "module can be loaded" do
      assert Code.ensure_loaded?(ThesisMonitor.CLI)
    end
  end
end
