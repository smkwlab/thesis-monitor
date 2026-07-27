defmodule ThesisMonitor.Commands.PullRequestStatsTest do
  use ExUnit.Case, async: true

  alias ThesisMonitor.Commands.PullRequestStats
  alias ThesisMonitor.Student

  # 集計マップの雛形（テストごとに必要なキーだけ上書きする）
  defp stats(overrides) do
    Map.merge(
      %{
        total: 0,
        open: 0,
        closed: 0,
        merged: 0,
        draft: 0,
        status: "No PRs",
        updated_at: nil,
        created_at: nil
      },
      Map.new(overrides)
    )
  end

  defp mock_output(pid) do
    %{
      info: fn msg -> send(pid, {:info, msg}) end,
      puts: fn text -> send(pid, {:puts, text}) end,
      warn: fn msg -> send(pid, {:warn, msg}) end,
      error: fn msg -> send(pid, {:error, msg}) end,
      print_table: fn headers, rows, _title, _opts ->
        send(pid, {:print_table, headers, rows})
      end
    }
  end

  test "module exists and has run function" do
    functions = PullRequestStats.__info__(:functions)
    assert {:run, 2} in functions
    assert {:run, 3} in functions
  end

  test "renders a table with PR counts per repository" do
    pid = self()

    students = [
      %Student{id: "k21rs001", repo_name: "k21rs001-sotsuron", repo_type: "sotsuron"}
    ]

    data_source = %{
      get_all_students: fn -> {:ok, students} end,
      filter_students_by_type: fn s, _type -> s end,
      get_pr_status_stats: fn _student, _state, _no_cache ->
        {:ok, stats(total: 3, open: 1, closed: 2, merged: 2, draft: 1, status: "In Progress")}
      end
    }

    deps = %{data_source: data_source, output: mock_output(pid)}

    PullRequestStats.run([], [], deps)

    assert_received {:print_table, headers, rows}
    assert "Total PRs" in headers
    assert "Merged" in headers
    row = Enum.find(rows, &(Enum.at(&1, 0) == "k21rs001"))
    assert row == ["k21rs001", "k21rs001-sotsuron", "3", "1", "2", "2", "1", "In Progress"]
  end

  test "passes the --type filter through to the data source" do
    pid = self()

    all = [
      %Student{id: "k1", repo_name: "k1-sotsuron", repo_type: "sotsuron"},
      %Student{id: "k2", repo_name: "k2-wr", repo_type: "wr"}
    ]

    filtered = [%Student{id: "k1", repo_name: "k1-sotsuron", repo_type: "sotsuron"}]

    data_source = %{
      get_all_students: fn -> {:ok, all} end,
      filter_students_by_type: fn _s, "thesis" ->
        send(pid, :type_filtered)
        filtered
      end,
      get_pr_status_stats: fn _student, _state, _no_cache -> {:ok, stats(total: 0)} end
    }

    deps = %{data_source: data_source, output: mock_output(pid)}

    PullRequestStats.run([], [type: "thesis"], deps)

    assert_received :type_filtered
    assert_received {:print_table, _headers, rows}
    assert length(rows) == 1
  end

  test "requests the given --state from the data source" do
    pid = self()
    students = [%Student{id: "k1", repo_name: "k1-sotsuron"}]

    data_source = %{
      get_all_students: fn -> {:ok, students} end,
      filter_students_by_type: fn s, _type -> s end,
      get_pr_status_stats: fn _student, state, _no_cache ->
        send(pid, {:state, state})
        {:ok, stats(total: 1, closed: 1, merged: 1, status: "Complete")}
      end
    }

    deps = %{data_source: data_source, output: mock_output(pid)}

    PullRequestStats.run([], [state: "closed"], deps)

    assert_received {:state, "closed"}
  end

  test "--state open keeps only repos with open PRs" do
    pid = self()

    students = [
      %Student{id: "k1", repo_name: "k1-sotsuron"},
      %Student{id: "k2", repo_name: "k2-sotsuron"}
    ]

    data_source = %{
      get_all_students: fn -> {:ok, students} end,
      filter_students_by_type: fn s, _type -> s end,
      get_pr_status_stats: fn student, _state, _no_cache ->
        case student.id do
          "k1" -> {:ok, stats(total: 1, open: 1, status: "In Progress")}
          "k2" -> {:ok, stats(total: 1, closed: 1, status: "Under Review")}
        end
      end
    }

    deps = %{data_source: data_source, output: mock_output(pid)}

    PullRequestStats.run([], [state: "open"], deps)

    assert_received {:print_table, _headers, rows}
    ids = Enum.map(rows, &Enum.at(&1, 0))
    assert ids == ["k1"]
  end

  test "--state closed keeps only repos with closed/merged and no open PRs" do
    pid = self()

    students = [
      %Student{id: "k1", repo_name: "k1-sotsuron"},
      %Student{id: "k2", repo_name: "k2-sotsuron"},
      %Student{id: "k3", repo_name: "k3-sotsuron"}
    ]

    data_source = %{
      get_all_students: fn -> {:ok, students} end,
      filter_students_by_type: fn s, _type -> s end,
      get_pr_status_stats: fn student, _state, _no_cache ->
        case student.id do
          # closed のみ → 残る
          "k1" -> {:ok, stats(total: 2, closed: 2, merged: 1, status: "Under Review")}
          # open あり → 除外
          "k2" -> {:ok, stats(total: 1, open: 1, status: "In Progress")}
          # PR なし → 除外
          "k3" -> {:ok, stats(total: 0)}
        end
      end
    }

    deps = %{data_source: data_source, output: mock_output(pid)}

    PullRequestStats.run([], [state: "closed"], deps)

    assert_received {:print_table, _headers, rows}
    ids = Enum.map(rows, &Enum.at(&1, 0))
    assert ids == ["k1"]
  end

  test "--review-requested keeps only repos awaiting review from the current user" do
    pid = self()

    students = [
      %Student{id: "k1", repo_name: "k1-sotsuron"},
      %Student{id: "k2", repo_name: "k2-sotsuron"}
    ]

    data_source = %{
      get_all_students: fn -> {:ok, students} end,
      filter_students_by_type: fn s, _type -> s end,
      get_pr_status_stats: fn _student, _state, _no_cache ->
        {:ok, stats(total: 1, open: 1, status: "In Progress")}
      end,
      get_current_github_user: fn -> {:ok, "toshi0806"} end,
      pr_review_requested?: fn student, "toshi0806", _no_cache ->
        {:ok, student.id == "k1"}
      end
    }

    deps = %{data_source: data_source, output: mock_output(pid)}

    PullRequestStats.run([], [review_requested: true], deps)

    assert_received {:print_table, _headers, rows}
    ids = Enum.map(rows, &Enum.at(&1, 0))
    assert ids == ["k1"]
  end

  test "--review-requested warns and skips filtering when the user is unknown" do
    pid = self()
    students = [%Student{id: "k1", repo_name: "k1-sotsuron"}]

    data_source = %{
      get_all_students: fn -> {:ok, students} end,
      filter_students_by_type: fn s, _type -> s end,
      get_pr_status_stats: fn _student, _state, _no_cache ->
        {:ok, stats(total: 1, open: 1)}
      end,
      get_current_github_user: fn -> {:error, :no_login} end,
      pr_review_requested?: fn _student, _username, _no_cache -> {:ok, false} end
    }

    deps = %{data_source: data_source, output: mock_output(pid)}

    PullRequestStats.run([], [review_requested: true], deps)

    assert_received {:warn, _msg}
    assert_received {:print_table, _headers, rows}
    # 絞り込まないので全 repo が残る
    assert length(rows) == 1
  end

  test "--sort updated orders by most recently updated PR (desc)" do
    pid = self()

    students = [
      %Student{id: "k1", repo_name: "k1-sotsuron"},
      %Student{id: "k2", repo_name: "k2-sotsuron"}
    ]

    data_source = %{
      get_all_students: fn -> {:ok, students} end,
      filter_students_by_type: fn s, _type -> s end,
      get_pr_status_stats: fn student, _state, _no_cache ->
        case student.id do
          "k1" -> {:ok, stats(total: 1, open: 1, updated_at: "2026-07-01T00:00:00Z")}
          "k2" -> {:ok, stats(total: 1, open: 1, updated_at: "2026-07-10T00:00:00Z")}
        end
      end
    }

    deps = %{data_source: data_source, output: mock_output(pid)}

    PullRequestStats.run([], [sort: "updated"], deps)

    assert_received {:print_table, _headers, rows}
    ids = Enum.map(rows, &Enum.at(&1, 0))
    assert ids == ["k2", "k1"]
  end

  test "default sort is by repository name; --reverse flips it" do
    pid = self()

    students = [
      %Student{id: "k2", repo_name: "b-repo"},
      %Student{id: "k1", repo_name: "a-repo"}
    ]

    data_source = %{
      get_all_students: fn -> {:ok, students} end,
      filter_students_by_type: fn s, _type -> s end,
      get_pr_status_stats: fn _student, _state, _no_cache -> {:ok, stats(total: 0)} end
    }

    deps = %{data_source: data_source, output: mock_output(pid)}

    PullRequestStats.run([], [reverse: true], deps)

    assert_received {:print_table, _headers, rows}
    repos = Enum.map(rows, &Enum.at(&1, 1))
    # 既定は repo 名昇順（a-repo, b-repo）→ reverse で降順
    assert repos == ["b-repo", "a-repo"]
  end

  test "json format emits parity fields" do
    pid = self()
    students = [%Student{id: "k1", repo_name: "k1-sotsuron"}]

    data_source = %{
      get_all_students: fn -> {:ok, students} end,
      filter_students_by_type: fn s, _type -> s end,
      get_pr_status_stats: fn _student, _state, _no_cache ->
        {:ok, stats(total: 2, open: 1, closed: 1, merged: 1, draft: 0, status: "In Progress")}
      end
    }

    deps = %{data_source: data_source, output: mock_output(pid)}

    PullRequestStats.run([], [format: "json"], deps)

    assert_received {:puts, json}
    assert [entry] = Jason.decode!(json)
    assert entry["repository"] == "k1-sotsuron"
    assert entry["total_prs"] == 2
    assert entry["merged_prs"] == 1
    assert entry["status"] == "In Progress"
  end

  test "csv format emits a header and one row per repository" do
    pid = self()
    students = [%Student{id: "k1", repo_name: "k1-sotsuron"}]

    data_source = %{
      get_all_students: fn -> {:ok, students} end,
      filter_students_by_type: fn s, _type -> s end,
      get_pr_status_stats: fn _student, _state, _no_cache ->
        {:ok, stats(total: 1, closed: 1, merged: 1, status: "Complete")}
      end
    }

    deps = %{data_source: data_source, output: mock_output(pid)}

    PullRequestStats.run([], [format: "csv"], deps)

    assert_received {:puts, csv}
    lines = String.split(csv, "\n")

    assert hd(lines) ==
             "student_id,repository,total_prs,open_prs,closed_prs,merged_prs,draft_prs,status"

    assert Enum.at(lines, 1) == "k1,k1-sotsuron,1,0,1,1,0,Complete"
  end
end
