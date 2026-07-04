defmodule ThesisMonitor.Commands.Activity do
  @moduledoc """
  最近のコミット活動表示コマンド
  """

  alias ThesisMonitor.{DataSource, Output}

  def run(args, opts) do
    run(args, opts, %{})
  end

  def run(args, opts, deps) do
    days = parse_days(args)

    output = deps[:output] || Output
    data_source = deps[:data_source] || DataSource

    output.info("Fetching recent commit activity (last #{days} days)...")

    {:ok, students} = data_source.get_all_students()
    activities = collect_activities(students, days)
    display_activities(activities, opts)
  end

  defp collect_activities(students, days) do
    students
    |> Task.async_stream(
      fn student ->
        case DataSource.get_recent_activity(student, days) do
          {:ok, [_ | _] = commits} ->
            {student, commits}

          _ ->
            nil
        end
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

  defp parse_days([days_str | _]) do
    case Integer.parse(days_str) do
      {days, _} when days > 0 -> days
      _ -> 7
    end
  end

  defp parse_days(_), do: 7

  defp display_activities([], _opts) do
    Output.info("\nNo recent activity found in student repositories.")
  end

  defp display_activities(activities, opts) do
    IO.puts("\n📈 Recent Commit Activity")
    IO.puts("======================================\n")

    case opts[:format] do
      "json" ->
        display_json(activities)

      _ ->
        display_text(activities)
    end
  end

  defp display_text(activities) do
    Enum.each(activities, fn {student, commits} ->
      IO.puts("[#{student.id}] #{student.repo_name}: #{length(commits)} commits")

      commits
      |> Enum.take(3)
      |> Enum.each(fn commit ->
        IO.puts("  - #{commit.message}")
      end)

      IO.puts("")
    end)
  end

  defp display_json(activities) do
    data =
      activities
      |> Enum.map(fn {student, commits} ->
        %{
          student_id: student.id,
          repository: student.repo_name,
          commit_count: length(commits),
          recent_commits: Enum.map(commits, &Map.take(&1, [:sha, :message, :author, :date]))
        }
      end)

    Jason.encode!(data, pretty: true) |> IO.puts()
  end
end
