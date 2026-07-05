defmodule ThesisMonitor.DataSource.GitHubAPI do
  @moduledoc """
  GitHub API経由でのデータ取得
  """

  alias ThesisMonitor.Student

  @base_url "https://api.github.com"

  @doc """
  リポジトリ API URL を構築（組織名は Config の github_org から取得）
  """
  def build_repo_url(repo_name) do
    "#{@base_url}/repos/#{org()}/#{repo_name}"
  end

  defp org, do: ThesisMonitor.Config.get(:github_org)

  @doc """
  リポジトリ情報を取得
  """
  def get_repository_info(%Student{repo_name: repo_name} = student) do
    url = build_repo_url(repo_name)

    case make_request(url) do
      {:ok, data} ->
        updated_student = %{
          student
          | exists: true,
            last_push: get_in(data, ["pushed_at"]),
            visibility: get_in(data, ["visibility"]),
            default_branch: get_in(data, ["default_branch"]) || "main"
        }

        {:ok, updated_student}

      {:error, 404} ->
        {:ok, %{student | exists: false}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  最新のブランチを取得（PR用ブランチを優先）
  """
  def get_latest_branch(%Student{repo_name: repo_name} = student) do
    url = build_repo_url(repo_name) <> "/branches"

    case make_request(url) do
      {:ok, branches} when is_list(branches) ->
        # ブランチ一覧から最新のブランチを選択
        # initialとreview-branchを除外し、PR用のブランチを優先
        latest_branch =
          branches
          |> Enum.reject(fn branch ->
            name = branch["name"]
            name == "initial" || name == "review-branch"
          end)
          |> Enum.max_by(
            fn branch ->
              # コミット日時を取得（APIに含まれていない場合は個別に取得が必要）
              {priority_score(branch["name"]), branch["name"]}
            end,
            fn -> nil end
          )

        if latest_branch do
          {:ok, latest_branch["name"]}
        else
          {:ok, student.default_branch || "main"}
        end

      {:error, 404} ->
        # リポジトリが存在しない場合はブランチ名を捏造しない
        {:ok, nil}

      {:error, _reason} ->
        {:ok, student.default_branch || "main"}
    end
  end

  # ブランチ名の優先順位を決定（数字が大きいほど優先）
  defp priority_score(branch_name) do
    cond do
      # abstract-20th などの形式
      String.match?(branch_name, ~r/^abstract-\d+/) ->
        extract_number(branch_name, ~r/abstract-(\d+)/)

      # 1st-draft, 2nd-draft などの形式
      String.match?(branch_name, ~r/^\d+[a-z]+-draft$/) ->
        extract_number(branch_name, ~r/^(\d+)/) + 1000

      # final-draft
      branch_name == "final-draft" ->
        10_000

      # main/master
      branch_name in ["main", "master"] ->
        100

      # その他
      true ->
        0
    end
  end

  defp extract_number(string, regex) do
    case Regex.run(regex, string) do
      [_, num_str] -> String.to_integer(num_str)
      _ -> 0
    end
  end

  @doc """
  ブランチ保護設定を確認
  """
  def check_branch_protection(%Student{repo_name: repo_name, default_branch: branch} = student) do
    url = build_repo_url(repo_name) <> "/branches/#{branch}/protection"

    case make_request(url) do
      {:ok, _data} ->
        {:ok, %{student | protection_status: :protected}}

      {:error, 404} ->
        {:ok, %{student | protection_status: :unprotected}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  最近のコミットを取得
  """
  def get_recent_commits(%Student{repo_name: repo_name}, days) do
    since =
      DateTime.utc_now()
      |> DateTime.add(-days * 24 * 60 * 60, :second)
      |> DateTime.to_iso8601()

    url = build_repo_url(repo_name) <> "/commits?since=#{since}"

    case make_request(url) do
      {:ok, commits} when is_list(commits) ->
        formatted_commits =
          commits
          |> Enum.take(10)
          |> Enum.map(&format_commit/1)

        {:ok, formatted_commits}

      {:ok, _} ->
        {:ok, []}

      {:error, _reason} ->
        {:ok, []}
    end
  end

  @doc """
  PR/Issue統計を取得
  """
  def get_pr_issue_stats(%Student{repo_name: repo_name}) do
    # get_pull_requests/3 と get_issues/2 は常に {:ok, list} を返す
    # （API エラー時は {:ok, []} に畳む）ため else 節は不要
    {:ok, open_prs} = get_pull_requests(repo_name, "open")
    {:ok, draft_prs} = get_pull_requests(repo_name, "open", draft: true)
    {:ok, open_issues} = get_issues(repo_name, "open")

    stats = %{
      open_prs: length(open_prs),
      draft_prs: length(draft_prs),
      open_issues: length(open_issues)
    }

    {:ok, stats}
  end

  defp get_pull_requests(repo_name, state, opts \\ []) do
    url = build_repo_url(repo_name) <> "/pulls?state=#{state}"

    url =
      if opts[:draft] do
        url <> "&draft=true"
      else
        url
      end

    case make_request(url) do
      {:ok, prs} when is_list(prs) -> {:ok, prs}
      _ -> {:ok, []}
    end
  end

  defp get_issues(repo_name, state) do
    url = build_repo_url(repo_name) <> "/issues?state=#{state}"

    case make_request(url) do
      {:ok, issues} when is_list(issues) ->
        # PRも含まれるので除外
        issues = Enum.reject(issues, &Map.has_key?(&1, "pull_request"))
        {:ok, issues}

      _ ->
        {:ok, []}
    end
  end

  defp format_commit(commit) do
    %{
      sha: get_in(commit, ["sha"]) |> String.slice(0, 7),
      message: get_in(commit, ["commit", "message"]) |> String.split("\n") |> List.first(),
      author: get_in(commit, ["commit", "author", "name"]),
      date: get_in(commit, ["commit", "author", "date"])
    }
  end

  defp make_request(url) do
    headers = [
      {"Accept", "application/vnd.github.v3+json"},
      {"Authorization", "Bearer #{get_token()}"},
      {"User-Agent", "ThesisMonitor/1.0"}
    ]

    case Req.get(url, headers: headers, retry: false) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, status}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_token do
    # 並列実行時でもTokenManagerがキャッシュを使用するため、
    # 実際にgh auth tokenが実行されるのは初回のみ
    ThesisMonitor.TokenManager.get_token()
  end
end
