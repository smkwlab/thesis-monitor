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

  # github_org 未設定なら "/repo" への静かな誤対象を避けて明示エラー（issue #28）
  defp org, do: ThesisMonitor.Config.require_github_org!(ThesisMonitor.Config.get(:github_org))

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

  @doc """
  オープン PR のうち「教員の返信待ち」の件数を返す（Issue #31）。

  各オープン PR について、学生の最新コミット時刻が教員の最新レビュー時刻より後、
  またはレビューが皆無（かつコミットあり）のものを「返信待ち」として数える。
  """
  def get_pending_review_count(%Student{repo_name: repo_name}) do
    {:ok, open_prs} = get_pull_requests(repo_name, "open")
    count = Enum.count(open_prs, &pr_pending_review?(repo_name, &1))
    {:ok, count}
  end

  defp pr_pending_review?(repo_name, pr) do
    number = pr["number"]
    student_login = get_in(pr, ["user", "login"])
    {:ok, commits} = get_pr_commits(repo_name, number)
    {:ok, reviews} = get_pr_reviews(repo_name, number)

    pending_review?(
      latest_commit_at(commits),
      latest_instructor_review_at(reviews, student_login)
    )
  end

  defp get_pr_commits(repo_name, number) do
    url = build_repo_url(repo_name) <> "/pulls/#{number}/commits?per_page=100"

    case make_request(url) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> {:ok, []}
    end
  end

  defp get_pr_reviews(repo_name, number) do
    url = build_repo_url(repo_name) <> "/pulls/#{number}/reviews?per_page=100"

    case make_request(url) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> {:ok, []}
    end
  end

  @doc false
  # PR の commits リストから最新のコミット時刻（ISO8601）を返す。空/非リストなら nil。
  # GitHub の日時は "...Z"（UTC・固定長）で辞書順 = 時系列順のため文字列比較で足りる。
  def latest_commit_at(commits) when is_list(commits) do
    commits
    |> Enum.map(&get_in(&1, ["commit", "committer", "date"]))
    |> Enum.reject(&is_nil/1)
    |> max_or_nil()
  end

  def latest_commit_at(_), do: nil

  @doc false
  # reviews から、学生本人（student_login）と bot を除いた「教員」レビューの
  # 最新 submitted_at を返す。該当なしなら nil。
  def latest_instructor_review_at(reviews, student_login) when is_list(reviews) do
    reviews
    |> Enum.reject(fn review ->
      login = get_in(review, ["user", "login"])
      type = get_in(review, ["user", "type"])

      is_nil(login) or login == student_login or type == "Bot" or
        String.ends_with?(login, "[bot]")
    end)
    |> Enum.map(&get_in(&1, ["submitted_at"]))
    |> Enum.reject(&is_nil/1)
    |> max_or_nil()
  end

  def latest_instructor_review_at(_, _), do: nil

  @doc false
  # 教員の返信待ちか。学生の最新コミットが教員の最新レビューより後、
  # またはレビュー皆無（かつコミットあり）なら true。
  def pending_review?(nil, _review_at), do: false
  def pending_review?(_commit_at, nil), do: true
  def pending_review?(commit_at, review_at), do: commit_at > review_at

  defp max_or_nil([]), do: nil
  defp max_or_nil(list), do: Enum.max(list)

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

  @doc """
  contents API でファイルを取得し、デコード済みのテキストを返す

  レジストリは private リポジトリのため、404（ファイル不在）と 401/403
  （トークンの権限不足）を区別して返す。権限不足を「存在しない」と
  誤解釈すると学生ゼロと沈黙するため、呼び出し側で必ず区別すること。
  """
  def get_file_contents(repo_full_name, path) do
    url = "#{@base_url}/repos/#{repo_full_name}/contents/#{path}"
    handle_contents_result(make_request(url))
  end

  @doc false
  # make_request の結果を contents API の意味論に写す（テスト可能な純粋関数）
  def handle_contents_result({:ok, body}), do: decode_contents_response(body)
  def handle_contents_result({:error, 404}), do: {:error, :not_found}

  def handle_contents_result({:error, status}) when status in [401, 403],
    do: {:error, :unauthorized}

  def handle_contents_result({:error, reason}), do: {:error, reason}

  @doc false
  # contents API の content は base64（60 桁ごとに改行入り）で返る
  def decode_contents_response(%{"content" => content, "encoding" => "base64"})
      when is_binary(content) do
    decoded =
      content
      |> String.replace(["\n", "\r"], "")
      |> Base.decode64()

    case decoded do
      {:ok, text} -> {:ok, text}
      :error -> {:error, :invalid_content}
    end
  end

  def decode_contents_response(_body), do: {:error, :invalid_content}

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
