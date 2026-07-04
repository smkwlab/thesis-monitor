defmodule ThesisMonitor.Commands.ActivityTest do
  use ExUnit.Case, async: true

  alias ThesisMonitor.Commands.Activity

  test "module exists and has run function" do
    functions = Activity.__info__(:functions)
    assert {:run, 2} in functions
  end

  test "module defines basic structure" do
    # Verify module loads without external dependencies
    assert Code.ensure_loaded?(Activity)
  end
end
