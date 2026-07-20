defmodule ThesisMonitor.Commands.SearchTest do
  use ExUnit.Case, async: true

  alias ThesisMonitor.Commands.Search
  alias ThesisMonitor.Student

  setup do
    sample_students = [
      %Student{
        id: "k21rs001",
        name: "田中太郎",
        repo_name: "k21rs001-sotsuron",
        type: "sotsuron",
        last_push: "2025-06-23T10:00:00Z",
        protection_status: :protected
      },
      %Student{
        id: "k22jk059",
        name: "佐藤花子",
        repo_name: "k22jk059-wr",
        type: "wr",
        last_push: "2025-06-24T15:30:00Z",
        protection_status: :unprotected
      }
    ]

    {:ok, students: sample_students}
  end

  describe "basic functionality" do
    test "module exists and has run function" do
      functions = Search.__info__(:functions)
      assert {:run, 2} in functions or {:run, 3} in functions
    end

    test "module defines basic structure" do
      assert Code.ensure_loaded?(Search)
    end
  end

  describe "argument validation" do
    test "shows error when no arguments provided" do
      pid = self()

      mock_output = %{
        error: fn msg -> send(pid, {:error, msg}) end,
        puts: fn text -> send(pid, {:puts, text}) end
      }

      mock_system_exit = fn code -> send(pid, {:exit, code}) end

      deps = %{
        output: mock_output,
        system_exit: mock_system_exit
      }

      Search.run([], [], deps)

      assert_received {:error, "検索キーワードが必要です"}
      assert_received {:puts, usage_text}
      assert String.contains?(usage_text, "使用法: thesis-monitor search")
      assert_received {:exit, 1}
    end

    test "shows error when too many arguments provided" do
      pid = self()

      mock_output = %{
        error: fn msg -> send(pid, {:error, msg}) end,
        puts: fn text -> send(pid, {:puts, text}) end
      }

      mock_system_exit = fn code -> send(pid, {:exit, code}) end

      deps = %{
        output: mock_output,
        system_exit: mock_system_exit
      }

      Search.run(["arg1", "arg2"], [], deps)

      assert_received {:error, "引数が多すぎます"}
      assert_received {:puts, usage_text}
      assert String.contains?(usage_text, "使用法: thesis-monitor search")
      assert_received {:exit, 1}
    end
  end

  describe "search functionality" do
    test "finds student by ID", %{students: students} do
      pid = self()

      mock_data_source = %{
        get_all_students: fn -> {:ok, students} end
      }

      mock_output = %{
        info: fn msg -> send(pid, {:info, msg}) end,
        puts: fn text -> send(pid, {:puts, text}) end
      }

      deps = %{
        data_source: mock_data_source,
        output: mock_output
      }

      Search.run(["k21rs001"], [], deps)

      assert_received {:info, "=== 学生情報 ==="}
      assert_received {:puts, "学生ID: k21rs001"}
    end

    test "shows the Poster label for poster students" do
      pid = self()

      poster_student = %Student{
        id: "k25gjk04",
        repo_name: "k25gjk04-midterm-poster",
        type: "poster",
        review_flow: true
      }

      deps = %{
        data_source: %{get_all_students: fn -> {:ok, [poster_student]} end},
        output: %{
          info: fn msg -> send(pid, {:info, msg}) end,
          puts: fn text -> send(pid, {:puts, text}) end
        }
      }

      Search.run(["k25gjk04"], [], deps)

      assert_received {:puts, "タイプ: Poster"}
    end
  end
end
