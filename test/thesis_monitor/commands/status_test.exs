defmodule ThesisMonitor.Commands.StatusTest do
  use ExUnit.Case, async: true

  alias ThesisMonitor.Commands.Status
  alias ThesisMonitor.Student

  describe "basic functionality" do
    test "module structure" do
      functions = Status.__info__(:functions)
      assert {:run, 2} in functions or {:run, 3} in functions
      assert Code.ensure_loaded?(Status)
    end

    test "handles empty student list" do
      pid = self()

      mock_data_source = %{
        get_all_students: fn -> {:ok, []} end,
        filter_students_by_type: fn students, _type -> students end,
        get_repositories_info: fn students -> Enum.map(students, &{:ok, &1}) end,
        needs_latest_branch?: fn _student -> false end,
        get_latest_branch: fn _student -> {:ok, "main"} end,
        check_branch_protection: fn student -> {:ok, student} end
      }

      mock_output = %{
        info: fn msg -> send(pid, {:info, msg}) end,
        puts: fn text -> send(pid, {:puts, text}) end,
        error: fn msg -> send(pid, {:error, msg}) end,
        warn: fn msg -> send(pid, {:warn, msg}) end,
        print_table: fn _headers, _rows, _title, _opts -> send(pid, {:print_table}) end
      }

      mock_token_manager = %{
        get_source: fn -> :config end
      }

      deps = %{
        data_source: mock_data_source,
        output: mock_output,
        token_manager: mock_token_manager
      }

      Status.run([], [], deps)

      # 基本的なメッセージが出力されることを確認
      assert_received {:info, "Fetching student repository status from GitHub..."}
      assert_received {:info, "Found 0 students total"}
      assert_received {:info, "After type filtering: 0 students"}
    end

    test "processes students with basic flow" do
      pid = self()

      students = [
        %Student{
          id: "k21rs001",
          name: "田中太郎",
          repo_name: "k21rs001-sotsuron",
          type: "sotsuron"
        }
      ]

      mock_data_source = %{
        get_all_students: fn -> {:ok, students} end,
        filter_students_by_type: fn students, nil -> students end,
        get_repositories_info: fn students -> Enum.map(students, &{:ok, &1}) end,
        needs_latest_branch?: fn _student -> false end,
        get_latest_branch: fn _student -> {:ok, "main"} end,
        check_branch_protection: fn student -> {:ok, student} end
      }

      mock_output = %{
        info: fn msg -> send(pid, {:info, msg}) end,
        puts: fn text -> send(pid, {:puts, text}) end,
        error: fn msg -> send(pid, {:error, msg}) end,
        warn: fn msg -> send(pid, {:warn, msg}) end,
        print_table: fn _headers, _rows, _title, _opts -> send(pid, {:print_table}) end
      }

      mock_token_manager = %{
        get_source: fn -> :config end
      }

      deps = %{
        data_source: mock_data_source,
        output: mock_output,
        token_manager: mock_token_manager
      }

      Status.run([], [], deps)

      assert_received {:info, "Fetching student repository status from GitHub..."}
      assert_received {:info, "Found 1 students total"}
      assert_received {:info, "After type filtering: 1 students"}
    end

    test "handles large student lists with rate limit warning" do
      pid = self()

      large_student_list =
        for i <- 1..50 do
          %Student{
            id: "k#{String.pad_leading(to_string(i), 2, "0")}rs001",
            name: "学生#{i}",
            repo_name: "k#{String.pad_leading(to_string(i), 2, "0")}rs001-sotsuron",
            type: "sotsuron"
          }
        end

      mock_data_source = %{
        get_all_students: fn -> {:ok, large_student_list} end,
        filter_students_by_type: fn students, nil -> students end,
        get_repositories_info: fn students -> Enum.map(students, &{:ok, &1}) end,
        needs_latest_branch?: fn _student -> false end,
        get_latest_branch: fn _student -> {:ok, "main"} end,
        check_branch_protection: fn student -> {:ok, student} end
      }

      mock_output = %{
        info: fn msg -> send(pid, {:info, msg}) end,
        puts: fn text -> send(pid, {:puts, text}) end,
        error: fn msg -> send(pid, {:error, msg}) end,
        warn: fn msg -> send(pid, {:warn, msg}) end,
        print_table: fn _headers, _rows, _title, _opts -> send(pid, {:print_table}) end
      }

      mock_token_manager = %{
        get_source: fn -> :config end
      }

      deps = %{
        data_source: mock_data_source,
        output: mock_output,
        token_manager: mock_token_manager
      }

      Status.run([], [], deps)

      assert_received {:info, "Found 50 students total"}
      assert_received {:info, "After type filtering: 50 students"}
      # 学生数によらず警告ノイズは出さない（issue #37）
      refute_received {:warn, _}
    end

    test "filters students by type" do
      pid = self()

      all_students = [
        %Student{id: "k1", type: "sotsuron"},
        %Student{id: "k2", type: "wr"}
      ]

      filtered_students = [%Student{id: "k1", type: "sotsuron"}]

      mock_data_source = %{
        get_all_students: fn -> {:ok, all_students} end,
        filter_students_by_type: fn _students, "sotsuron" -> filtered_students end,
        get_repositories_info: fn students -> Enum.map(students, &{:ok, &1}) end,
        needs_latest_branch?: fn _student -> false end,
        get_latest_branch: fn _student -> {:ok, "main"} end,
        check_branch_protection: fn student -> {:ok, student} end
      }

      mock_output = %{
        info: fn msg -> send(pid, {:info, msg}) end,
        puts: fn text -> send(pid, {:puts, text}) end,
        error: fn msg -> send(pid, {:error, msg}) end,
        warn: fn msg -> send(pid, {:warn, msg}) end,
        print_table: fn _headers, _rows, _title, _opts -> send(pid, {:print_table}) end
      }

      mock_token_manager = %{
        get_source: fn -> :config end
      }

      deps = %{
        data_source: mock_data_source,
        output: mock_output,
        token_manager: mock_token_manager
      }

      Status.run([], [type: "sotsuron"], deps)

      assert_received {:info, "Found 2 students total"}
      assert_received {:info, "After type filtering: 1 students"}
    end

    test "shows a Pending column with the count when --pending-reviews is set (issue #31)" do
      pid = self()

      students = [
        %Student{
          id: "k24rs062",
          repo_name: "k24rs062-ise-report1",
          type: "ise",
          repo_type: "ise"
        }
      ]

      mock_data_source = %{
        get_all_students: fn -> {:ok, students} end,
        filter_students_by_type: fn s, _type -> s end,
        get_repositories_info: fn s -> Enum.map(s, &{:ok, &1}) end,
        needs_latest_branch?: fn _student -> false end,
        get_latest_branch: fn _student -> {:ok, "main"} end,
        check_branch_protection: fn student -> {:ok, student} end,
        get_pending_review_count: fn _student -> {:ok, 2} end
      }

      mock_output = %{
        info: fn msg -> send(pid, {:info, msg}) end,
        puts: fn text -> send(pid, {:puts, text}) end,
        error: fn msg -> send(pid, {:error, msg}) end,
        warn: fn msg -> send(pid, {:warn, msg}) end,
        print_table: fn headers, rows, _title, _opts ->
          send(pid, {:print_table, headers, rows})
        end
      }

      mock_token_manager = %{get_source: fn -> :config end}

      deps = %{
        data_source: mock_data_source,
        output: mock_output,
        token_manager: mock_token_manager
      }

      Status.run([], [pending_reviews: true], deps)

      assert_received {:print_table, headers, rows}
      assert "Pending" in headers
      assert Enum.any?(rows, fn row -> "2" in row end)
    end

    test "does not fetch pending reviews when the option is absent (issue #31)" do
      pid = self()

      students = [%Student{id: "k24rs062", repo_name: "k24rs062-ise-report1", type: "ise"}]

      mock_data_source = %{
        get_all_students: fn -> {:ok, students} end,
        filter_students_by_type: fn s, _type -> s end,
        get_repositories_info: fn s -> Enum.map(s, &{:ok, &1}) end,
        needs_latest_branch?: fn _student -> false end,
        get_latest_branch: fn _student -> {:ok, "main"} end,
        check_branch_protection: fn student -> {:ok, student} end,
        get_pending_review_count: fn _student ->
          send(pid, :pending_called)
          {:ok, 0}
        end
      }

      mock_output = %{
        info: fn msg -> send(pid, {:info, msg}) end,
        puts: fn text -> send(pid, {:puts, text}) end,
        error: fn msg -> send(pid, {:error, msg}) end,
        warn: fn msg -> send(pid, {:warn, msg}) end,
        print_table: fn headers, rows, _title, _opts ->
          send(pid, {:print_table, headers, rows})
        end
      }

      deps = %{
        data_source: mock_data_source,
        output: mock_output,
        token_manager: %{get_source: fn -> :config end}
      }

      Status.run([], [], deps)

      assert_received {:print_table, headers, _rows}
      refute "Pending" in headers
      refute_received :pending_called
    end
  end

  describe "archived display" do
    test "shows archived in the Latest Branch column for archived rows" do
      pid = self()

      students = [
        %Student{
          id: "k21rs001",
          repo_name: "k21rs001-sotsuron",
          review_flow: true,
          archived_at: nil
        },
        %Student{
          id: "k20rs005",
          repo_name: "k20rs005-sotsuron",
          review_flow: true,
          archived_at: "2025-03-14T00:00:00Z"
        }
      ]

      mock_data_source = %{
        get_all_students: fn -> {:ok, students} end,
        filter_students_by_type: fn students, _type -> students end,
        get_repositories_info: fn students -> Enum.map(students, &{:ok, &1}) end,
        needs_latest_branch?: fn student ->
          student.review_flow && not Student.archived?(student)
        end,
        get_latest_branch: fn _student -> {:ok, "2nd-draft"} end,
        check_branch_protection: fn student -> {:ok, student} end
      }

      mock_output = %{
        info: fn msg -> send(pid, {:info, msg}) end,
        puts: fn text -> send(pid, {:puts, text}) end,
        error: fn msg -> send(pid, {:error, msg}) end,
        warn: fn msg -> send(pid, {:warn, msg}) end,
        print_table: fn headers, rows, _title, _opts ->
          send(pid, {:print_table, headers, rows})
        end
      }

      deps = %{
        data_source: mock_data_source,
        output: mock_output,
        token_manager: %{get_source: fn -> :config end}
      }

      Status.run([], [show_archived: true], deps)

      assert_received {:print_table, headers, rows}
      branch_index = Enum.find_index(headers, &(&1 == "Latest Branch"))

      active_row = Enum.find(rows, &(Enum.at(&1, 0) == "k21rs001"))
      archived_row = Enum.find(rows, &(Enum.at(&1, 0) == "k20rs005"))

      assert Enum.at(active_row, branch_index) == "2nd-draft"
      assert Enum.at(archived_row, branch_index) == "archived"
    end

    test "treats an empty archived_at as not archived" do
      pid = self()

      students = [
        %Student{
          id: "k99rs001",
          repo_name: "k99rs001-sotsuron",
          review_flow: false,
          archived_at: ""
        }
      ]

      mock_data_source = %{
        get_all_students: fn -> {:ok, students} end,
        filter_students_by_type: fn students, _type -> students end,
        get_repositories_info: fn students -> Enum.map(students, &{:ok, &1}) end,
        needs_latest_branch?: fn student ->
          student.review_flow && not Student.archived?(student)
        end,
        get_latest_branch: fn _student -> {:ok, "2nd-draft"} end,
        check_branch_protection: fn student -> {:ok, student} end
      }

      mock_output = %{
        info: fn msg -> send(pid, {:info, msg}) end,
        puts: fn text -> send(pid, {:puts, text}) end,
        error: fn msg -> send(pid, {:error, msg}) end,
        warn: fn msg -> send(pid, {:warn, msg}) end,
        print_table: fn headers, rows, _title, _opts ->
          send(pid, {:print_table, headers, rows})
        end
      }

      deps = %{
        data_source: mock_data_source,
        output: mock_output,
        token_manager: %{get_source: fn -> :config end}
      }

      Status.run([], [show_archived: true], deps)

      assert_received {:print_table, headers, rows}
      branch_index = Enum.find_index(headers, &(&1 == "Latest Branch"))
      row = Enum.find(rows, &(Enum.at(&1, 0) == "k99rs001"))

      # archived_at: "" は archived 扱いしない（Student.archived?/1 と同じ境界）。
      # review_flow: false で latest_branch は nil のままなので N/A になる。
      assert Enum.at(row, branch_index) == "N/A"
    end
  end

  describe "error handling" do
    test "handles data source error gracefully" do
      pid = self()

      mock_data_source = %{
        get_all_students: fn -> {:error, "connection failed"} end
      }

      mock_output = %{
        info: fn msg -> send(pid, {:info, msg}) end,
        puts: fn text -> send(pid, {:puts, text}) end,
        error: fn msg -> send(pid, {:error, msg}) end,
        warn: fn msg -> send(pid, {:warn, msg}) end,
        print_table: fn _headers, _rows, _title, _opts -> send(pid, {:print_table}) end
      }

      mock_token_manager = %{
        get_source: fn -> :config end
      }

      deps = %{
        data_source: mock_data_source,
        output: mock_output,
        token_manager: mock_token_manager
      }

      # エラーが発生することを期待
      assert_raise MatchError, fn ->
        Status.run([], [], deps)
      end

      assert_received {:info, "Fetching student repository status from GitHub..."}
    end
  end
end
