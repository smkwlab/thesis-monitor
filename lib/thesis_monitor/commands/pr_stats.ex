defmodule ThesisMonitor.Commands.PullRequestStats do
  @moduledoc """
  PR/Issue統計表示コマンド
  """

  alias ThesisMonitor.{DataSource, Output}

  def run(_args, opts, deps \\ %{}) do
    data_source = deps[:data_source] || DataSource
    output = deps[:output] || Output

    output.info("Collecting PR/Issue statistics from GitHub...")

    {:ok, students} = data_source.get_all_students()
    stats = collect_pr_stats(students, data_source)
    display_stats(stats, opts)
  end

  defp collect_pr_stats(students, data_source) do
    students
    |> Task.async_stream(
      fn student ->
        {:ok, stats} = data_source.get_pr_stats(student)
        {student, stats}
      end,
      ordered: false,
      timeout: 10_000,
      max_concurrency: 10
    )
    |> Enum.map(fn
      {:ok, result} -> result
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp display_stats(stats, opts) do
    case opts[:format] do
      "json" ->
        display_json(stats)

      "csv" ->
        display_csv(stats)

      _ ->
        display_text(stats)
    end
  end

  defp display_text(stats) do
    IO.puts("\n📊 Pull Request and Issue Statistics")
    IO.puts("====================================\n")

    if Enum.empty?(stats) do
      IO.puts("No repositories found with PR/Issue activity.")
    else
      Enum.each(stats, fn {student, pr_stats} ->
        IO.puts("[#{student.id}] #{student.repo_name}")
        IO.puts("  Open PRs: #{pr_stats.open_prs} (Draft: #{pr_stats.draft_prs})")
        IO.puts("  Open Issues: #{pr_stats.open_issues}")
        IO.puts("")
      end)
    end
  end

  defp display_json(stats) do
    data =
      stats
      |> Enum.map(fn {student, pr_stats} ->
        %{
          student_id: student.id,
          repository: student.repo_name,
          open_prs: pr_stats.open_prs,
          draft_prs: pr_stats.draft_prs,
          open_issues: pr_stats.open_issues
        }
      end)

    Jason.encode!(data, pretty: true) |> IO.puts()
  end

  defp display_csv(stats) do
    IO.puts("student_id,repository,open_prs,draft_prs,open_issues")

    stats
    |> Enum.each(fn {student, pr_stats} ->
      IO.puts(
        "#{student.id},#{student.repo_name},#{pr_stats.open_prs}," <>
          "#{pr_stats.draft_prs},#{pr_stats.open_issues}"
      )
    end)
  end
end
