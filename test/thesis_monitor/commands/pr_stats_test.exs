defmodule ThesisMonitor.Commands.PullRequestStatsTest do
  use ExUnit.Case, async: true

  alias ThesisMonitor.Commands.PullRequestStats

  test "module exists and has run function" do
    functions = PullRequestStats.__info__(:functions)
    assert {:run, 2} in functions
  end

  test "module defines basic structure" do
    # Verify module loads without external dependencies
    assert Code.ensure_loaded?(PullRequestStats)
  end
end
