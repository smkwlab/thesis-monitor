defmodule ThesisMonitor.OutputTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias ThesisMonitor.Output

  setup do
    # Ensure clean state for each test.
    # 前のテストが起動した Agent は test process の終了と同時に死ぬため、
    # 名前解決後・stop 前に消えるレースがある。pid で止めて :exit は握りつぶす
    case Process.whereis(Output) do
      nil ->
        :ok

      pid ->
        try do
          Agent.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end

    :ok
  end

  describe "start_link/1" do
    test "starts with default verbose false" do
      {:ok, _pid} = Output.start_link()
      assert Output.verbose?() == false
    end

    test "starts with verbose true when specified" do
      {:ok, _pid} = Output.start_link(verbose: true)
      assert Output.verbose?() == true
    end

    test "starts with verbose false when explicitly specified" do
      {:ok, _pid} = Output.start_link(verbose: false)
      assert Output.verbose?() == false
    end
  end

  describe "set_verbose/1" do
    setup do
      {:ok, _pid} = Output.start_link()
      :ok
    end

    test "sets verbose to true" do
      Output.set_verbose(true)
      assert Output.verbose?() == true
    end

    test "sets verbose to false" do
      Output.set_verbose(false)
      assert Output.verbose?() == false
    end
  end

  describe "verbose?/0" do
    test "returns current verbose state" do
      {:ok, _pid} = Output.start_link(verbose: true)
      assert Output.verbose?() == true
    end
  end

  describe "info/1" do
    test "prints message when verbose is true" do
      {:ok, _pid} = Output.start_link(verbose: true)

      result =
        capture_io(fn ->
          Output.info("test message")
        end)

      # timestamp starts with year
      assert result =~ "[20"
      assert result =~ "test message"
    end

    test "does not print when verbose is false" do
      {:ok, _pid} = Output.start_link(verbose: false)

      result =
        capture_io(fn ->
          Output.info("test message")
        end)

      assert result == ""
    end
  end

  describe "success/1" do
    test "prints success message with color" do
      result =
        capture_io(fn ->
          Output.success("operation completed")
        end)

      assert result =~ "[SUCCESS]"
      assert result =~ "operation completed"
    end
  end

  describe "warn/1" do
    test "prints warning message with color" do
      result =
        capture_io(fn ->
          Output.warn("potential issue")
        end)

      assert result =~ "[WARNING]"
      assert result =~ "potential issue"
    end
  end

  describe "error/1" do
    test "prints error message with color" do
      result =
        capture_io(:stderr, fn ->
          Output.error("something went wrong")
        end)

      assert result =~ "[ERROR]"
      assert result =~ "something went wrong"
    end
  end

  describe "table formatting" do
    test "print_table/2 with basic data" do
      headers = ["Name", "Status"]
      rows = [["Alice", "Active"], ["Bob", "Inactive"]]

      result =
        capture_io(fn ->
          Output.print_table(headers, rows)
        end)

      assert result =~ "Name"
      assert result =~ "Status"
      assert result =~ "Alice"
      assert result =~ "Bob"
    end

    test "print_table/3 with title" do
      headers = ["Name", "Status"]
      rows = [["Alice", "Active"]]

      result =
        capture_io(fn ->
          Output.print_table(headers, rows, "Test Table")
        end)

      assert result =~ "Test Table"
      assert result =~ "Name"
      assert result =~ "Status"
      assert result =~ "Alice"
    end

    test "print_table/4 with options" do
      headers = ["Name", "Status"]
      rows = [["Alice", "Active"]]

      result =
        capture_io(fn ->
          Output.print_table(headers, rows, "Test Table", [])
        end)

      assert result =~ "Test Table"
      assert result =~ "Name"
      assert result =~ "Alice"
    end

    test "print_table/2 with empty rows" do
      headers = ["Name", "Status"]
      rows = []

      result =
        capture_io(fn ->
          Output.print_table(headers, rows)
        end)

      # Empty rows should show "No data available" message
      assert result =~ "No data available"
    end
  end
end
