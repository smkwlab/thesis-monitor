defmodule ThesisMonitor.Commands.Check do
  @moduledoc """
  ブランチ保護設定確認コマンド
  """

  alias ThesisMonitor.{DataSource, Output}

  def run(_args, opts, deps \\ %{}) do
    data_source = deps[:data_source] || DataSource
    output = deps[:output] || Output

    if opts[:verbose] do
      output.info("Checking branch protection status...")
    end

    {:ok, students} = data_source.get_all_students()
    results = check_protection_status(students, data_source)
    unprotected = filter_unprotected(results)
    display_results(unprotected, opts, output)
  end

  defp check_protection_status(students, data_source) do
    students
    |> data_source.get_repositories_info()
    |> Enum.map(fn
      {:ok, student} ->
        case data_source.check_branch_protection(student) do
          {:ok, updated} -> updated
          _ -> student
        end

      _ ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp filter_unprotected(results) do
    results
    |> Enum.filter(&(&1.exists && &1.protection_status == :unprotected))
  end

  defp display_results([], _opts, output) do
    output.success("\nAll repositories are properly protected! ✅")
  end

  defp display_results(unprotected, _opts, output) do
    count = length(unprotected)
    output.warn("\nFound #{count} unprotected repositories:")

    Enum.each(unprotected, fn student ->
      IO.puts("  - #{student.id} (#{student.repo_name})")
    end)

    IO.puts("\nTo set up protection, run:")
    IO.puts("  thesis-monitor bulk")
  end
end
