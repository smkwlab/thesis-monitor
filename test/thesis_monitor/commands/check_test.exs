defmodule ThesisMonitor.Commands.CheckTest do
  use ExUnit.Case, async: true

  alias ThesisMonitor.Commands.Check

  test "module exists and has run function" do
    functions = Check.__info__(:functions)
    assert {:run, 2} in functions
  end

  test "module defines basic structure" do
    # Verify module loads without external dependencies
    assert Code.ensure_loaded?(Check)
  end
end
