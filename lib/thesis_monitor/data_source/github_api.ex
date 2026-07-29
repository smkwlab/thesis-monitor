defmodule ThesisMonitor.DataSource.GitHubAPI do
  @moduledoc """
  GitHub API経由でのデータ取得
  """

  alias ThesisMonitor.Student
  alias ToolKit.GitHub.Client

  @base_url "https://api.github.com"
  @user_agent "ThesisMonitor/1.0"

  @doc """
  リポジトリ API URL を構築（組織名は Config の github_org から取得）
  """
  def build_repo_url(repo_name) do
    "#{@base_url}/repos/#{org()}/#{repo_name}"
  end

  # github_org 未設定なら "/repo" への静かな誤対象を避けて明示エラー（issue #28）
  defp org, do: ThesisMonitor.Config.require_github_org!(ThesisMonitor.Config.get(:github_org))

  # 教員（レビュアー）ログイン一覧。--pending-reviews の学生 commit 判定に使う（issue #65）
  defp instructors, do: ThesisMonitor.Config.get(:instructors) || []

  @doc """
  リポジトリ情報を取得
  """
  def get_repository_info(%Student{repo_name: repo_name} = student) do
    case Client.get_repository("#{org()}/#{repo_name}", client_opts()) do
      {:ok, data} ->
        updated_student = %{
          student
          | exists: true,
            last_push: get_in(data, ["pushed_at"]),
            visibility: get_in(data, ["visibility"]),
            default_branch: get_in(data, ["default_branch"]) || "main"
        }

        {:ok, updated_student}

      {:error, :not_found} ->
        {:ok, %{student | exists: false}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  最新のブランチを取得（PR用ブランチを優先）
  """
  def get_latest_branch(%Student{repo_name: repo_name} = student) do
    case Client.list_branches("#{org()}/#{repo_name}", client_opts()) do
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

      {:error, :not_found} ->
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
    path = "/repos/#{org()}/#{repo_name}/branches/#{branch}/protection"

    case Client.get(path, client_opts()) do
      {:ok, _data} ->
        {:ok, %{student | protection_status: :protected}}

      {:error, :not_found} ->
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

    case Client.list_commits("#{org()}/#{repo_name}", [since: since] ++ client_opts()) do
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
  registry-manager `pr-status` 相当の PR 集計をリポジトリ単位で返す（Issue #59）。

  `state`（"open" / "closed" / "all"）で取得対象を絞り、total / open / closed /
  merged / draft / status / updated_at / created_at を集計する。取得した PR 一覧は
  `ToolKit.Cache`（category "pr-status"）にキャッシュし、`no_cache: true` で
  バイパスする。集計ロジックは `extract_pr_stats/1`（純粋関数）が担う。
  """
  def get_pr_status_stats(student, state, no_cache \\ false)

  def get_pr_status_stats(%Student{repo_name: repo_name}, state, no_cache) do
    prs = fetch_prs_cached(repo_name, state, no_cache)
    {:ok, extract_pr_stats(prs)}
  end

  @doc """
  指定ユーザーにレビューリクエストが来ている open PR をリポジトリが持つか判定する
  （Issue #59）。

  GitHub はレビュー提出でユーザーを `requested_reviewers` から外し、再リクエストで
  戻すため、`requested_reviewers` への所属がそのまま「いまレビュー待ちか」を表す。
  これは status の Pending（学生コミット時刻 vs 教員レビュー時刻。`pending_review?/2`）
  とは別セマンティクスであり、意図的に別実装とする。open PR のみを対象にする。
  """
  def pr_review_requested?(student, username, no_cache \\ false)

  def pr_review_requested?(%Student{repo_name: repo_name}, username, no_cache)
      when is_binary(username) do
    prs = fetch_prs_cached(repo_name, "open", no_cache)
    {:ok, Enum.any?(prs, &pr_awaiting_review_from?(&1, username))}
  end

  def pr_review_requested?(_student, _username, _no_cache), do: {:ok, false}

  @doc """
  現在の GitHub ユーザー（`login`）を取得する（`--review-requested` の対象判定用）。
  """
  def get_current_user do
    case Client.get("/user", client_opts()) do
      {:ok, %{"login" => login}} when is_binary(login) -> {:ok, login}
      {:ok, _body} -> {:error, :no_login}
      {:error, reason} -> {:error, reason}
    end
  end

  # PR 一覧を state 付きで取得し、per-repo・per-state でキャッシュする。
  # no_cache 時はキャッシュを読まず常に API を叩く。キャッシュ層は JSON 文字列を
  # 扱うため、取得結果を Jason でエンコードして保存し、読み出し時にデコードする。
  defp fetch_prs_cached(repo_name, state, no_cache) do
    key = "#{repo_name}:#{state}"

    fetch_fn = fn ->
      {:ok, prs} = get_pull_requests(repo_name, state)
      {:ok, Jason.encode!(prs)}
    end

    case ThesisMonitor.Cache.pr_get_or_fetch(key, fetch_fn, no_cache) do
      {:ok, json} when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, prs} when is_list(prs) -> prs
          _ -> []
        end

      _ ->
        []
    end
  end

  @doc false
  # PR 一覧から registry-manager pr-status 相当の集計マップを作る（純粋関数）。
  def extract_pr_stats(prs) when is_list(prs) do
    total = length(prs)
    open = count_prs_by_state(prs, "open")
    closed = count_prs_by_state(prs, "closed")
    merged = count_merged_prs(prs)
    draft = count_draft_prs(prs)
    {updated_at, created_at} = extract_pr_timestamps(prs)

    %{
      total: total,
      open: open,
      closed: closed,
      merged: merged,
      draft: draft,
      status: determine_pr_status(open, merged, total),
      updated_at: updated_at,
      created_at: created_at
    }
  end

  def extract_pr_stats(_) do
    %{
      total: 0,
      open: 0,
      closed: 0,
      merged: 0,
      draft: 0,
      status: "No PRs",
      updated_at: nil,
      created_at: nil
    }
  end

  defp count_prs_by_state(prs, state), do: Enum.count(prs, &(Map.get(&1, "state") == state))

  # merged_at の有無で merged を判定（GitHub の merged フラグは PR 詳細にしか
  # 含まれないため、一覧では merged_at で判定するのが確実。rm と同じ）
  defp count_merged_prs(prs), do: Enum.count(prs, &(not is_nil(Map.get(&1, "merged_at"))))

  defp count_draft_prs(prs), do: Enum.count(prs, &(Map.get(&1, "draft", false) == true))

  # "No PRs" / "In Progress"（open あり）/ "Complete"（全 merged）/ "Under Review"
  defp determine_pr_status(_open, _merged, 0), do: "No PRs"
  defp determine_pr_status(open, _merged, _total) when open > 0, do: "In Progress"
  defp determine_pr_status(_open, merged, total) when merged == total, do: "Complete"
  defp determine_pr_status(_open, _merged, _total), do: "Under Review"

  # 最新の updated_at / created_at を返す。GitHub の日時は "...Z"（UTC・固定長）で
  # 辞書順 = 時系列順のため文字列の最大値で足りる。PR が無ければ {nil, nil}。
  defp extract_pr_timestamps([]), do: {nil, nil}

  defp extract_pr_timestamps(prs) do
    {most_recent_timestamp(prs, "updated_at"), most_recent_timestamp(prs, "created_at")}
  end

  defp most_recent_timestamp(prs, field) do
    prs
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(&>=/2, fn -> nil end)
  end

  @doc false
  # PR オブジェクトの requested_reviewers から user login のリストを取り出す（純粋関数）。
  def extract_requested_reviewer_logins(%{"requested_reviewers" => reviewers})
      when is_list(reviewers) do
    reviewers |> Enum.map(&Map.get(&1, "login")) |> Enum.reject(&is_nil/1)
  end

  def extract_requested_reviewer_logins(_), do: []

  @doc false
  # PR が指定ユーザーのレビュー待ちか（requested_reviewers に含まれるか。大小無視）。
  def pr_awaiting_review_from?(pr, username) when is_map(pr) and is_binary(username) do
    pr
    |> extract_requested_reviewer_logins()
    |> Enum.any?(fn login -> String.downcase(login) == String.downcase(username) end)
  end

  def pr_awaiting_review_from?(_, _), do: false

  @doc """
  「教員の返信待ち」かをリポジトリ単位で返す（Issue #31 / #46）。

  全オープン PR の学生コミット・教員レビューをリポジトリ単位に集約し、
  学生の最新コミット時刻が教員の最新レビュー時刻より後、またはレビューが
  皆無（かつコミットあり）なら返信待ちとする。draft PR サイクルでは下位の
  PR（0th-draft → main など）が開いたまま残り教員の返答は最新 draft PR に
  移るため、PR 単位で比較すると下位 PR が常に返信待ちに見えてしまう。
  """
  def get_pending_review_status(%Student{repo_name: repo_name}) do
    {:ok, open_prs} = get_pull_requests(repo_name, "open")
    instructors = instructors()
    pairs = Enum.map(open_prs, &pr_activity_pair(repo_name, &1, instructors))
    {:ok, repo_pending_review?(pairs)}
  end

  # PR の {学生の最新コミット時刻, 教員の最新レビュー時刻} を返す
  defp pr_activity_pair(repo_name, pr, instructors) do
    number = pr["number"]
    student_login = get_in(pr, ["user", "login"])
    {:ok, commits} = get_pr_commits(repo_name, number)
    {:ok, reviews} = get_pr_reviews(repo_name, number)

    {
      latest_student_commit_at(commits, student_login, instructors),
      latest_instructor_review_at(reviews, student_login)
    }
  end

  @doc false
  # 全オープン PR ぶんの activity pair をリポジトリ単位に集約して判定する。
  # オープン PR が無ければ（pairs が空なら）コミットなし扱いで false。
  def repo_pending_review?(pairs) do
    {commit_ats, review_ats} = Enum.unzip(pairs)

    pending_review?(
      commit_ats |> Enum.reject(&is_nil/1) |> max_or_nil(),
      review_ats |> Enum.reject(&is_nil/1) |> max_or_nil()
    )
  end

  defp get_pr_commits(repo_name, number) do
    # per_page=100（GitHub の上限）まで取得。ISE レポートで 1 PR に 100 コミット超は
    # 非現実的なためページネーションは追わない。
    path = "/repos/#{org()}/#{repo_name}/pulls/#{number}/commits"

    case Client.get(path, [params: [per_page: 100]] ++ client_opts()) do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> {:ok, []}
    end
  end

  defp get_pr_reviews(repo_name, number) do
    # per_page=100（GitHub の上限）まで取得。1 PR に 100 レビュー超は非現実的なため
    # ページネーションは追わない。
    result =
      Client.list_pull_request_reviews(
        "#{org()}/#{repo_name}",
        number,
        [per_page: 100] ++ client_opts()
      )

    case result do
      {:ok, list} when is_list(list) -> {:ok, list}
      _ -> {:ok, []}
    end
  end

  @doc false
  # PR の commits リストから学生の最新コミット時刻（ISO8601）を返す。該当なし/非リスト
  # なら nil。merge コミットは除外する（Issue #46）。
  #
  # 「学生のコミット」の判定（Issue #65）:
  #   - instructors（教員ログイン一覧）が空: 従来どおり PR 作者ログインと一致するもの。
  #   - instructors が非空: bot と instructors 以外の author を学生とみなす。学生が
  #     ローカルで別 GitHub アカウント名義で commit しても（PR 作者と不一致でも）拾えるので、
  #     返信待ちの見逃しを防ぐ。教員の propagate コミットと bot は除外する。
  # author が GitHub アカウントに紐付かないコミットは、学生の git 設定不備で返信待ちを
  # 見逃さないよう学生のものとみなす。
  # committer.date（リポジトリに反映された時刻）を使う。学生が push / rebase した後の
  # 時刻をレビュー時刻と比較したいため、原著時刻の author.date より committer.date が適切。
  # GitHub の日時は "...Z"（UTC・固定長）で辞書順 = 時系列順のため文字列比較で足りる。
  def latest_student_commit_at(commits, student_login, instructors \\ [])

  def latest_student_commit_at(commits, student_login, instructors)
      when is_list(commits) and is_list(instructors) do
    commits
    |> Enum.reject(&merge_commit?/1)
    |> Enum.filter(&student_commit?(&1, student_login, instructors))
    |> Enum.map(&get_in(&1, ["commit", "committer", "date"]))
    |> Enum.reject(&is_nil/1)
    |> max_or_nil()
  end

  def latest_student_commit_at(_, _, _), do: nil

  defp merge_commit?(commit), do: length(commit["parents"] || []) > 1

  defp student_commit?(commit, student_login, instructors) do
    case get_in(commit, ["author", "login"]) do
      nil ->
        true

      login ->
        cond do
          bot_login?(login) -> false
          instructors == [] -> login == student_login
          true -> login not in instructors
        end
    end
  end

  defp bot_login?(login) when is_binary(login), do: String.ends_with?(login, "[bot]")
  defp bot_login?(_), do: false

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
    # per_page=100（GitHub の上限）まで取得。closed/all はページ数が増えうるが、
    # 学生リポジトリで 1 repo に 100 PR 超は非現実的なためページネーションは追わない。
    params =
      if opts[:draft],
        do: [state: state, draft: true, per_page: 100],
        else: [state: state, per_page: 100]

    path = "/repos/#{org()}/#{repo_name}/pulls"

    case Client.get(path, [params: params] ++ client_opts()) do
      {:ok, prs} when is_list(prs) -> {:ok, prs}
      _ -> {:ok, []}
    end
  end

  defp get_issues(repo_name, state) do
    path = "/repos/#{org()}/#{repo_name}/issues"

    case Client.get(path, [params: [state: state]] ++ client_opts()) do
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
    repo_full_name
    |> Client.get_file_contents(path, client_opts())
    |> handle_contents_result()
  end

  @doc false
  # リクエスト結果を contents API の意味論に写す（テスト可能な純粋関数）。
  # Client は 404 / 401 / 403 を分類済み（:not_found / :unauthorized）で返すが、
  # 生のステータス整数を受けた場合も同じ意味論に写す
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

  # Client に渡す共通オプション。token はプロバイダ注入で TokenManager に委ね、
  # 現行の優先順位（config > GITHUB_TOKEN > gh auth token）を維持する。
  # 並列実行時でも TokenManager がキャッシュを使用するため、
  # 実際に gh auth token が実行されるのは初回のみ
  defp client_opts do
    [
      token_provider: fn -> {:ok, ThesisMonitor.TokenManager.get_token()} end,
      user_agent: @user_agent
    ]
  end
end
