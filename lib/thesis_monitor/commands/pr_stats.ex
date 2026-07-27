defmodule ThesisMonitor.Commands.PullRequestStats do
  @moduledoc """
  PR 統計表示コマンド（registry-manager `pr-status` 相当、Issue #59）

  レジストリの全リポジトリについて Pull Request の集計
  （total / open / closed / merged / draft / status）を表示する。

  ## オプション

  - `--type`   リポジトリタイプで絞り込み（status と同じ語彙）
  - `--state`  取得対象の PR 状態（open / closed / all、既定 all）
  - `--review-requested`  自分にレビューリクエストが来ている open PR を持つ repo のみ
  - `--sort`   ソートキー（repository / updated / created）
  - `--reverse`（-r）ソート順を反転
  - `--format` 出力形式（table / json / csv）
  - `--no-cache`  キャッシュを読まず常に最新を取得

  `--state` は「取得する PR の状態」を絞るため、`open` 指定時は closed / merged が
  0 に、`closed` 指定時は open が 0 になる（registry-manager と同じ挙動）。
  """

  alias ThesisMonitor.{DataSource, Output}

  # PR 情報が無い repo の既定集計
  @empty_stats %{
    total: 0,
    open: 0,
    closed: 0,
    merged: 0,
    draft: 0,
    status: "No PRs",
    updated_at: nil,
    created_at: nil
  }

  def run(args, opts), do: run(args, opts, %{})

  def run(_args, opts, deps) do
    data_source = deps[:data_source] || DataSource
    output = deps[:output] || Output

    state = opts[:state] || "all"
    no_cache = opts[:no_cache] || false

    call_output(output, :info, ["Collecting PR statistics from GitHub..."])

    {:ok, all_students} = call_data_source(data_source, :get_all_students, [])

    students =
      call_data_source(data_source, :filter_students_by_type, [all_students, opts[:type]])

    stats =
      students
      |> collect_pr_stats(data_source, state, no_cache)
      |> filter_by_state(state)
      |> filter_by_review_requested(opts, deps)
      |> sort_stats(opts)

    display_stats(stats, opts, output)
  end

  # 各リポジトリの PR 集計を並列取得する
  defp collect_pr_stats(students, data_source, state, no_cache) do
    students
    |> Task.async_stream(
      fn student ->
        case call_data_source(data_source, :get_pr_status_stats, [student, state, no_cache]) do
          {:ok, stats} -> {student, stats}
          _ -> {student, @empty_stats}
        end
      end,
      ordered: true,
      timeout: 15_000,
      max_concurrency: 10,
      on_timeout: :kill_task
    )
    |> Enum.zip(students)
    |> Enum.map(fn
      {{:ok, result}, _original} -> result
      {_, original} -> {original, @empty_stats}
    end)
  end

  # --state による repo 単位の絞り込み（registry-manager と同じ規則）
  # open:   open > 0 の repo だけ
  # closed: closed + merged > 0 かつ open == 0 の repo だけ
  # all:    絞り込まない
  defp filter_by_state(stats, "open") do
    Enum.filter(stats, fn {_student, s} -> s.open > 0 end)
  end

  defp filter_by_state(stats, "closed") do
    Enum.filter(stats, fn {_student, s} -> s.closed + s.merged > 0 and s.open == 0 end)
  end

  defp filter_by_state(stats, _all), do: stats

  # --review-requested: 自分にレビューリクエストが来ている open PR を持つ repo のみ。
  # 現在ユーザーが取れない場合は警告して絞り込まない（rm と同じフェイルセーフ）。
  defp filter_by_review_requested(stats, opts, deps) do
    if opts[:review_requested] do
      data_source = deps[:data_source] || DataSource
      output = deps[:output] || Output
      no_cache = opts[:no_cache] || false

      case call_data_source(data_source, :get_current_github_user, []) do
        {:ok, username} when is_binary(username) ->
          filter_repos_by_review_requested(stats, data_source, username, no_cache)

        _ ->
          call_output(output, :warn, [
            "Could not determine current GitHub user; skipping --review-requested filter"
          ])

          stats
      end
    else
      stats
    end
  end

  defp filter_repos_by_review_requested(stats, data_source, username, no_cache) do
    stats
    |> Task.async_stream(
      fn {student, _s} = pair ->
        {pair, review_requested?(data_source, student, username, no_cache)}
      end,
      ordered: true,
      timeout: 15_000,
      max_concurrency: 10,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, {pair, true}} -> pair
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp review_requested?(data_source, student, username, no_cache) do
    case call_data_source(data_source, :pr_review_requested?, [student, username, no_cache]) do
      {:ok, requested} -> requested
      _ -> false
    end
  end

  # ソート: repository（repo 名）/ updated / created。
  # --review-requested 指定かつ --sort 未指定なら updated を既定にする（rm と同じ）。
  defp sort_stats(stats, opts) do
    sort_key = effective_sort(opts[:sort], opts[:review_requested])

    sorted =
      case sort_key do
        "updated" -> Enum.sort_by(stats, &sort_timestamp(&1, :updated_at), {:desc, DateTime})
        "created" -> Enum.sort_by(stats, &sort_timestamp(&1, :created_at), {:desc, DateTime})
        _repository -> Enum.sort_by(stats, fn {student, _s} -> student.repo_name end)
      end

    if opts[:reverse], do: Enum.reverse(sorted), else: sorted
  end

  defp effective_sort(nil, true), do: "updated"
  defp effective_sort(nil, _), do: "repository"
  defp effective_sort(sort, _), do: sort

  @epoch ~U[1970-01-01 00:00:00Z]

  defp sort_timestamp({_student, stats}, field) do
    case Map.get(stats, field) do
      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> @epoch
        end

      _ ->
        @epoch
    end
  end

  defp display_stats(stats, opts, output) do
    case opts[:format] do
      "json" -> display_json(stats, output)
      "csv" -> display_csv(stats, output)
      _ -> display_table(stats, output)
    end
  end

  defp display_table(stats, output) do
    headers = [
      "Student ID",
      "Repository",
      "Total PRs",
      "Open",
      "Closed",
      "Merged",
      "Draft",
      "Status"
    ]

    rows =
      Enum.map(stats, fn {student, s} ->
        [
          student.id,
          student.repo_name,
          to_string(s.total),
          to_string(s.open),
          to_string(s.closed),
          to_string(s.merged),
          to_string(s.draft),
          s.status
        ]
      end)

    call_output(output, :print_table, [
      headers,
      rows,
      "Pull Request Statistics",
      [format: :compact]
    ])

    call_output(output, :puts, ["\n📊 Summary: Repositories: #{length(stats)}"])
  end

  defp display_json(stats, output) do
    data =
      Enum.map(stats, fn {student, s} ->
        %{
          student_id: student.id,
          repository: student.repo_name,
          total_prs: s.total,
          open_prs: s.open,
          closed_prs: s.closed,
          merged_prs: s.merged,
          draft_prs: s.draft,
          status: s.status
        }
      end)

    call_output(output, :puts, [Jason.encode!(data, pretty: true)])
  end

  defp display_csv(stats, output) do
    header = "student_id,repository,total_prs,open_prs,closed_prs,merged_prs,draft_prs,status"

    rows =
      Enum.map(stats, fn {student, s} ->
        "#{student.id},#{student.repo_name},#{s.total},#{s.open}," <>
          "#{s.closed},#{s.merged},#{s.draft},#{s.status}"
      end)

    call_output(output, :puts, [Enum.join([header | rows], "\n")])
  end

  # module / map 両対応のディスパッチ（status.ex と同じ規約）
  defp call_output(output, function, args) when is_atom(output), do: apply(output, function, args)

  defp call_output(output, function, args) when is_map(output),
    do: output[function] |> apply(args)

  defp call_data_source(data_source, function, args) when is_atom(data_source),
    do: apply(data_source, function, args)

  defp call_data_source(data_source, function, args) when is_map(data_source),
    do: data_source[function] |> apply(args)
end
