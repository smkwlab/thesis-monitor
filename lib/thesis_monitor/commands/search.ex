defmodule ThesisMonitor.Commands.Search do
  @moduledoc """
  学生検索コマンド
  """

  alias ThesisMonitor.{DataSource, Output, Student}

  def run(args, opts, deps \\ %{}) do
    output = deps[:output] || Output
    system_exit = deps[:system_exit] || (&System.halt/1)

    case args do
      [search_term] ->
        search_student(search_term, opts, deps)

      [] ->
        call_output(output, :error, ["検索キーワードが必要です"])
        show_usage(output)
        system_exit.(1)

      _ ->
        call_output(output, :error, ["引数が多すぎます"])
        show_usage(output)
        system_exit.(1)
    end
  end

  defp search_student(search_term, opts, deps) do
    data_source = deps[:data_source] || DataSource
    output = deps[:output] || Output

    {:ok, students} = call_data_source(data_source, :get_all_students, [])

    case find_student(students, search_term) do
      nil ->
        call_output(output, :error, ["学生が見つかりません: #{search_term}"])
        System.halt(1)

      student ->
        display_student(student, opts, output)
    end
  end

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

  defp find_student(students, search_term) do
    Enum.find(students, fn student ->
      # ログインIDで完全一致
      # 氏名で部分一致
      # リポジトリ名で完全一致
      student.id == search_term ||
        (student.name && String.contains?(student.name, search_term)) ||
        student.repo_name == search_term
    end)
  end

  defp display_student(student, opts, output) do
    case opts[:format] do
      "json" ->
        display_json(student, output)

      "csv" ->
        display_csv(student, output)

      _ ->
        display_table(student, opts, output)
    end
  end

  defp display_table(student, opts, output) do
    call_output(output, :info, ["=== 学生情報 ==="])
    call_output(output, :puts, ["学生ID: #{student.id}"])
    call_output(output, :puts, ["氏名: #{Student.format_name(student, opts)}"])
    call_output(output, :puts, ["リポジトリ: #{student.repo_name}"])
    call_output(output, :puts, ["タイプ: #{format_type(student.type)}"])

    call_output(output, :puts, ["ステータス: #{Student.repo_status(student)}"])

    if student.last_push do
      call_output(output, :puts, ["最終更新: #{Student.format_last_update(student)}"])
    end

    if student.protection_status do
      call_output(output, :puts, ["ブランチ保護: #{Student.protection_icon(student)}"])
    end
  end

  defp display_json(student, output) do
    data = %{
      student_id: student.id,
      name: student.name,
      repository: student.repo_name,
      type: student.type,
      status: Student.repo_status(student),
      last_update: student.last_push,
      protection_status: student.protection_status
    }

    Jason.encode!(data, pretty: true) |> then(&call_output(output, :puts, [&1]))
  end

  defp display_csv(student, output) do
    call_output(output, :puts, [
      "student_id,name,repository,type,status,last_update,protection_status"
    ])

    call_output(output, :puts, [
      "#{student.id},#{student.name || "N/A"},#{student.repo_name},#{student.type || "N/A"},#{Student.repo_status(student)},#{Student.format_last_update(student)},#{student.protection_status}"
    ])
  end

  defp format_type(nil), do: "N/A"
  defp format_type("wr"), do: "Weekly Report"
  defp format_type("thesis-report"), do: "Thesis Report"
  defp format_type("ise"), do: "ISE Report"
  defp format_type("master"), do: "Master Thesis"
  defp format_type("latex"), do: "LaTeX"
  defp format_type("sotsuron"), do: "Sotsuron"
  defp format_type(type), do: type

  defp show_usage(output) do
    call_output(output, :puts, [
      """
      使用法: thesis-monitor search [オプション] <検索キー>

      学生情報を検索・表示します。

      引数:
          <検索キー>      学生ID、氏名（部分一致）、またはリポジトリ名で検索

      オプション:
          -f, --format        出力形式 (table, json, csv) [デフォルト: table]
          --fullname          名前を省略せずに全文表示
          --verbose           詳細情報を表示

      例:
          thesis-monitor search k92rs004        # 学生IDで検索
          thesis-monitor search "田中"          # 氏名で部分一致検索
          thesis-monitor search --format json k92rs004  # JSON形式で出力
      """
    ])
  end
end
