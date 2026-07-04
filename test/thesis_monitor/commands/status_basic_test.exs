defmodule ThesisMonitor.Commands.StatusBasicTest do
  use ExUnit.Case, async: true

  alias ThesisMonitor.Commands.Status

  describe "basic functionality" do
    test "module exists and has run function" do
      functions = Status.__info__(:functions)
      assert {:run, 2} in functions or {:run, 3} in functions
    end

    test "module defines basic structure" do
      assert Code.ensure_loaded?(Status)
    end

    test "has expected function count" do
      functions = Status.__info__(:functions)
      # Test that the module compiles and has expected structure
      assert length(functions) >= 2
    end
  end
end
