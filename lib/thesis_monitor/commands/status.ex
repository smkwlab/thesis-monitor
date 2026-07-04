defmodule ThesisMonitor.Commands.Status do
  @moduledoc """
  学生リポジトリのステータス表示コマンド
  """

  alias ThesisMonitor.{DataSource, Output, Student}

  def run(_args, opts, deps \\ %{}) do
    data_source = deps[:data_source] || DataSource
    output = deps[:output] || Output

    call_output(output, :info, ["Fetching student repository status from GitHub..."])

    {:ok, all_students} = call_data_source(data_source, :get_all_students, [])
    process_students(all_students, opts, deps)
  end

  defp process_students(all_students, opts, deps) do
    data_source = deps[:data_source] || DataSource
    output = deps[:output] || Output

    call_output(output, :info, ["Found #{length(all_students)} students total"])

    # リポジトリタイプでフィルタリング
    students =
      call_data_source(data_source, :filter_students_by_type, [all_students, opts[:type]])

    call_output(output, :info, ["After type filtering: #{length(students)} students"])

    # APIレート制限チェック
    check_rate_limit(length(students), output)

    # リポジトリ情報を並列取得
    students_with_info = fetch_repository_info(students, data_source)
    log_token_source(students_with_info, output, deps)

    # 結果処理と表示
    handle_results(students, students_with_info, opts, deps)
  end

  defp fetch_repository_info(students, data_source) do
    call_data_source(data_source, :get_repositories_info, [students])
    |> process_repository_results()
  end

  defp process_repository_results(results) do
    results
    |> Enum.map(&handle_repository_result/1)
    |> Enum.reject(&is_nil/1)
  end

  defp handle_repository_result({:ok, student}), do: student

  defp handle_repository_result({:error, 401}) do
    # Output is handled at a higher level
    nil
  end

  defp handle_repository_result({:error, _}), do: nil

  defp log_token_source(students_with_info, output, deps) do
    if !Enum.empty?(students_with_info) do
      token_manager = deps[:token_manager] || ThesisMonitor.TokenManager

      case call_token_manager(token_manager, :get_source, []) do
        :config -> call_output(output, :info, ["Token source: Configuration file"])
        :env -> call_output(output, :info, ["Token source: Environment variable"])
        :gh_cli -> call_output(output, :info, ["Token source: GitHub CLI"])
        :none -> call_output(output, :info, ["Token source: None"])
        _ -> :ok
      end
    end
  end

  defp handle_results(students, students_with_info, opts, deps) do
    output = deps[:output] || Output
    data_source = deps[:data_source] || DataSource

    if Enum.empty?(students_with_info) && !Enum.empty?(students) do
      call_output(output, :warn, ["Displaying local data only (GitHub API unavailable)"])
      display_results(students, opts, output)
    else
      final_students = maybe_fetch_protection_status(students_with_info, opts, data_source)
      display_results(final_students, opts, output)
    end
  end

  defp maybe_fetch_protection_status(students_with_info, opts, data_source) do
    students =
      if opts[:show_protection] do
        fetch_protection_status_for_students(students_with_info, data_source)
      else
        students_with_info
      end

    # 最新ブランチ情報を取得（デフォルトで取得）
    fetch_latest_branches_for_students(students, data_source)
  end

  defp fetch_protection_status_for_students(students_with_info, data_source) do
    students_with_info
    |> Task.async_stream(&fetch_protection_status(&1, data_source),
      ordered: true,
      timeout: 5_000,
      max_concurrency: 10
    )
    |> process_protection_results()
  end

  defp process_protection_results(results) do
    results
    |> Enum.map(fn
      {:ok, student} -> student
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp fetch_protection_status(student, data_source) do
    case call_data_source(data_source, :check_branch_protection, [student]) do
      {:ok, updated_student} -> updated_student
      _ -> student
    end
  end

  defp fetch_latest_branches_for_students(students, data_source) do
    students
    |> Task.async_stream(&fetch_latest_branch(&1, data_source),
      ordered: true,
      timeout: 5_000,
      max_concurrency: 10
    )
    |> process_latest_branch_results()
  end

  defp process_latest_branch_results(results) do
    results
    |> Enum.map(fn {:ok, student} -> student end)
  end

  defp fetch_latest_branch(student, data_source) do
    if call_data_source(data_source, :needs_latest_branch?, [student]) do
      {:ok, branch} = call_data_source(data_source, :get_latest_branch, [student])
      %{student | latest_branch: branch}
    else
      student
    end
  end

  defp check_rate_limit(student_count, output) do
    # 簡易的なレート制限チェック
    estimated_calls = student_count * 3

    if estimated_calls > 100 do
      call_output(output, :warn, ["Large number of API calls required: ~#{estimated_calls}"])
      call_output(output, :warn, ["Consider using cache or limiting concurrent requests"])
    end
  end

  defp display_results(students, opts, output) do
    # ソート処理（表示前に実施）
    sorted_students = sort_students(students, opts)

    case opts[:format] do
      "json" ->
        display_json(sorted_students, opts, output)

      "csv" ->
        display_csv(sorted_students, opts, output)

      _ ->
        display_table(sorted_students, opts, output)
    end

    # サマリー表示
    display_summary(sorted_students, opts, output)
  end

  defp display_table(students, opts, output) do
    # Name列をStudent IDとRepositoryの間に配置
    base_headers = ["Student ID", "Name", "Repository"]
    type_headers = if opts[:long], do: ["Type"], else: []
    # デフォルトで表示
    branch_headers = ["Latest Branch"]
    status_headers = if opts[:show_status], do: ["Status"], else: []
    protection_headers = if opts[:show_protection], do: ["Protection"], else: []
    update_headers = ["Last Update"]

    headers =
      base_headers ++
        type_headers ++ branch_headers ++ status_headers ++ protection_headers ++ update_headers

    rows =
      students
      |> Enum.map(fn student ->
        # Name列をStudent IDとRepositoryの間に配置
        base_row = [
          student.id,
          Student.format_name(student, opts),
          student.repo_name
        ]

        type_row =
          if opts[:long], do: [format_type(student.type)], else: []

        # デフォルトで表示
        branch_row = [format_latest_branch(student)]

        status_row =
          if opts[:show_status], do: [Student.repo_status(student)], else: []

        protection_row =
          if opts[:show_protection], do: [Student.protection_icon(student)], else: []

        update_row = [Student.format_last_update(student)]
        base_row ++ type_row ++ branch_row ++ status_row ++ protection_row ++ update_row
      end)

    call_output(output, :print_table, [
      headers,
      rows,
      "Student Thesis Repository Status",
      [format: :compact]
    ])
  end

  defp display_json(students, opts, output) do
    data =
      students
      |> Enum.map(fn student ->
        base_data = %{
          student_id: student.id,
          name: Student.format_name(student, opts),
          repository: student.repo_name,
          type: student.type,
          last_update: student.last_push
        }

        base_data =
          if opts[:show_status] do
            Map.put(base_data, :status, Student.repo_status(student))
          else
            base_data
          end

        if opts[:show_protection] do
          Map.put(base_data, :protection, student.protection_status)
        else
          base_data
        end
      end)

    Jason.encode!(data, pretty: true) |> then(&call_output(output, :puts, [&1]))
  end

  defp display_csv(students, opts, output) do
    # name列をStudent IDとRepositoryの間に配置
    base_header = "student_id,name,repository"
    type_header = if opts[:long], do: ",type", else: ""
    status_header = if opts[:show_status], do: ",status", else: ""
    protection_header = if opts[:show_protection], do: ",protection", else: ""
    update_header = ",last_update"

    call_output(output, :puts, [
      base_header <> type_header <> status_header <> protection_header <> update_header
    ])

    students
    |> Enum.each(fn student ->
      base_data =
        "#{student.id},#{Student.format_name(student, opts)},#{student.repo_name}"

      type_data = if opts[:long], do: ",#{student.type || "N/A"}", else: ""
      status_data = if opts[:show_status], do: ",#{Student.repo_status(student)}", else: ""
      protection_data = if opts[:show_protection], do: ",#{student.protection_status}", else: ""
      update_data = ",#{Student.format_last_update(student)}"

      call_output(output, :puts, [
        base_data <> type_data <> status_data <> protection_data <> update_data
      ])
    end)
  end

  defp display_summary(students, opts, output) do
    total = length(students)
    base_summary = "📊 Summary: Total: #{total}"

    protection_summary =
      if opts[:show_protection] do
        protected = Enum.count(students, &(&1.protection_status == :protected))
        unprotected = Enum.count(students, &(&1.protection_status == :unprotected))
        ", Protected: #{protected}, Unprotected: #{unprotected}"
      else
        ""
      end

    call_output(output, :puts, ["\n" <> base_summary <> protection_summary])
  end

  defp format_type(nil), do: "N/A"
  defp format_type("wr"), do: "Weekly Report"
  defp format_type("thesis-report"), do: "Thesis Report"
  defp format_type("ise"), do: "ISE Report"
  defp format_type("thesis"), do: "Thesis"
  defp format_type("sotsuron"), do: "Sotsuron"
  defp format_type(type), do: type

  defp format_latest_branch(%Student{latest_branch: nil}), do: "N/A"
  defp format_latest_branch(%Student{latest_branch: branch}), do: branch

  # ソート処理
  defp sort_students(students, opts) do
    sorted =
      if opts[:t] do
        # 時刻順でソート
        Enum.sort_by(students, &parse_last_push_time/1, &compare_time/2)
      else
        # デフォルトは学籍番号順（既にDataSourceでソート済み）
        students
      end

    # -r オプションで逆順
    if opts[:r] do
      Enum.reverse(sorted)
    else
      sorted
    end
  end

  # 最終更新時刻をパース（nil対応）
  defp parse_last_push_time(%Student{last_push: nil}), do: nil

  defp parse_last_push_time(%Student{last_push: last_push}) do
    case DateTime.from_iso8601(last_push) do
      {:ok, datetime, _} -> datetime
      _ -> nil
    end
  end

  # 時刻比較（nilは最後に）
  defp compare_time(nil, nil), do: true
  defp compare_time(nil, _), do: false
  defp compare_time(_, nil), do: true
  defp compare_time(dt1, dt2), do: DateTime.compare(dt1, dt2) != :lt

  # Helper functions to handle both module and map calls
  defp call_output(output, function, args) when is_atom(output) do
    apply(output, function, args)
  end

  defp call_output(output, function, args) when is_map(output) do
    output[function] |> apply(args)
  end

  defp call_data_source(data_source, function, args) when is_atom(data_source) do
    apply(data_source, function, args)
  end

  defp call_data_source(data_source, function, args) when is_map(data_source) do
    data_source[function] |> apply(args)
  end

  defp call_token_manager(token_manager, function, args) when is_atom(token_manager) do
    apply(token_manager, function, args)
  end

  defp call_token_manager(token_manager, function, args) when is_map(token_manager) do
    token_manager[function] |> apply(args)
  end
end
