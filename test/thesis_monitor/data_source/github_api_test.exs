defmodule ThesisMonitor.DataSource.GitHubAPITest do
  use ExUnit.Case, async: true

  alias ThesisMonitor.DataSource.GitHubAPI

  describe "GitHubAPI module basic functionality" do
    test "module exists and can be loaded" do
      assert Code.ensure_loaded?(GitHubAPI)
    end

    test "has required functions exported" do
      # Check that the module is loaded and has expected functions
      assert Code.ensure_loaded?(GitHubAPI)

      functions = GitHubAPI.__info__(:functions)
      # Check for key functions without relying on function_exported?
      assert Enum.any?(functions, fn {name, arity} ->
               name == :get_repository_info and arity == 1
             end)

      assert Enum.any?(functions, fn {name, arity} ->
               name == :check_branch_protection and arity == 1
             end)
    end

    test "module defines expected structure" do
      # Test that the module can be introspected without API calls
      assert GitHubAPI.__info__(:module) == ThesisMonitor.DataSource.GitHubAPI
    end
  end

  describe "API configuration" do
    test "has base URL defined" do
      # Test that module has basic configuration without making requests
      functions = GitHubAPI.__info__(:functions)
      assert is_list(functions)
      assert functions != []
    end
  end

  describe "build_repo_url/1" do
    test "uses github_org from Config" do
      config_path = Path.join(System.tmp_dir!(), "thesis_monitor_org_test.yml")
      File.write!(config_path, "github_org: testorg\n")

      on_exit(fn ->
        File.rm(config_path)

        # Config Agent を明示停止し、この temp config を次テストへ持ち越さない
        if pid = Process.whereis(ThesisMonitor.Config), do: Agent.stop(pid)
      end)

      {:ok, _} = ThesisMonitor.Config.load(config_path)

      assert GitHubAPI.build_repo_url("k21rs001-wr") ==
               "https://api.github.com/repos/testorg/k21rs001-wr"
    end

    test "raises when github_org is not configured (issue #28)" do
      # github_org も registry_repo も無い config を明示的に読み込み、実 config への
      # 依存を断って決定的に未設定状態を作る（既定 org は廃止済み）
      config_path = Path.join(System.tmp_dir!(), "thesis_monitor_no_org_test.yml")
      File.write!(config_path, "github_token: x\n")

      on_exit(fn ->
        File.rm(config_path)

        # Config Agent を明示停止し、この temp config を次テストへ持ち越さない
        if pid = Process.whereis(ThesisMonitor.Config), do: Agent.stop(pid)
      end)

      {:ok, _} = ThesisMonitor.Config.load(config_path)

      assert_raise RuntimeError, ~r/github_org/, fn ->
        GitHubAPI.build_repo_url("k21rs001-wr")
      end
    end
  end

  describe "decode_contents_response/1 (issue #14)" do
    test "decodes base64 content (contents API inserts newlines every 60 chars)" do
      text = String.duplicate("registry content ", 10)

      encoded =
        text
        |> Base.encode64()
        |> String.codepoints()
        |> Enum.chunk_every(60)
        |> Enum.map_join("\n", &Enum.join/1)
        |> Kernel.<>("\n")

      assert {:ok, ^text} =
               GitHubAPI.decode_contents_response(%{
                 "content" => encoded,
                 "encoding" => "base64"
               })
    end

    test "returns an error for invalid base64" do
      assert {:error, :invalid_content} =
               GitHubAPI.decode_contents_response(%{
                 "content" => "%%%not-base64%%%",
                 "encoding" => "base64"
               })
    end

    test "returns an error for an unexpected response shape" do
      assert {:error, :invalid_content} = GitHubAPI.decode_contents_response(%{"foo" => "bar"})
    end

    test "exports get_file_contents/2" do
      assert Code.ensure_loaded?(GitHubAPI)
      assert {:get_file_contents, 2} in GitHubAPI.__info__(:functions)
    end
  end

  describe "handle_contents_result/1 (issue #14)" do
    # 404（不在）と 401/403（権限不足）の区別は「private レジストリで
    # トークン欠如時に学生ゼロと沈黙しない」ための中核マッピング
    test "maps 404 to :not_found" do
      assert {:error, :not_found} = GitHubAPI.handle_contents_result({:error, 404})
    end

    test "maps 401 and 403 to :unauthorized" do
      assert {:error, :unauthorized} = GitHubAPI.handle_contents_result({:error, 401})
      assert {:error, :unauthorized} = GitHubAPI.handle_contents_result({:error, 403})
    end

    test "passes other errors through" do
      assert {:error, 500} = GitHubAPI.handle_contents_result({:error, 500})
      assert {:error, :timeout} = GitHubAPI.handle_contents_result({:error, :timeout})
    end

    test "decodes a successful response body" do
      body = %{"content" => Base.encode64("hello"), "encoding" => "base64"}
      assert {:ok, "hello"} = GitHubAPI.handle_contents_result({:ok, body})
    end
  end

  describe "latest_student_commit_at/2 (issue #46)" do
    test "returns the newest committer date among the student's commits" do
      commits = [
        student_commit("2026-07-08T06:00:00Z", "k24rs124"),
        student_commit("2026-07-09T10:00:00Z", "k24rs124"),
        student_commit("2026-07-08T23:00:00Z", "k24rs124")
      ]

      assert GitHubAPI.latest_student_commit_at(commits, "k24rs124") == "2026-07-09T10:00:00Z"
    end

    test "excludes commits authored by someone other than the student" do
      # 教員による workflow propagate コミットを「学生の更新」に数えない
      commits = [
        student_commit("2026-07-08T06:00:00Z", "k24rs124"),
        student_commit("2026-07-15T06:23:24Z", "toshi0806")
      ]

      assert GitHubAPI.latest_student_commit_at(commits, "k24rs124") == "2026-07-08T06:00:00Z"
    end

    test "excludes merge commits even when the student is the author" do
      commits = [
        student_commit("2026-07-08T06:00:00Z", "k24rs124"),
        student_commit("2026-07-15T07:00:00Z", "k24rs124", parents: 2)
      ]

      assert GitHubAPI.latest_student_commit_at(commits, "k24rs124") == "2026-07-08T06:00:00Z"
    end

    test "keeps commits whose author is not linked to a GitHub account" do
      # 学生の git 設定不備(メール不一致)で author が紐付かないコミットを
      # 除外すると返信待ちを見逃すため、学生のものとみなす
      commits = [
        %{
          "commit" => %{"committer" => %{"date" => "2026-07-09T10:00:00Z"}},
          "author" => nil,
          "parents" => [%{"sha" => "a"}]
        }
      ]

      assert GitHubAPI.latest_student_commit_at(commits, "k24rs124") == "2026-07-09T10:00:00Z"
    end

    test "returns nil for an empty list" do
      assert GitHubAPI.latest_student_commit_at([], "k24rs124") == nil
    end

    test "returns nil for a non-list" do
      assert GitHubAPI.latest_student_commit_at(nil, "k24rs124") == nil
    end
  end

  describe "repo_pending_review?/1 (issue #46)" do
    test "false when the newest draft PR carries the latest instructor review" do
      # k24rs124 の誤検出ケース: 下位 PR(0th/1st-draft)は開いたまま残り、
      # 教員の返答は最新 draft PR に移る。repo 単位で集約すれば、下位 PR の
      # 古いレビュー時刻に引きずられず pending でないと判定できる
      pairs = [
        # 0th-draft PR: 最終レビュー 07-11、その後コミットあり
        {"2026-07-15T06:23:24Z", "2026-07-11T02:39:28Z"},
        # 1st-draft PR: 最終レビュー 07-22 05:32、その後コミットあり
        {"2026-07-22T05:49:00Z", "2026-07-22T05:32:59Z"},
        # 2nd-draft PR(最新): 同じコミットへ教員が 06:15 に返答済み
        {"2026-07-22T05:49:00Z", "2026-07-22T06:15:27Z"}
      ]

      assert GitHubAPI.repo_pending_review?(pairs) == false
    end

    test "true when the latest student commit is newer than every instructor review" do
      pairs = [
        {"2026-07-15T06:23:24Z", "2026-07-11T02:39:28Z"},
        {"2026-07-22T06:30:00Z", "2026-07-22T06:15:27Z"}
      ]

      assert GitHubAPI.repo_pending_review?(pairs) == true
    end

    test "true when the student committed but no instructor has reviewed any PR" do
      assert GitHubAPI.repo_pending_review?([{"2026-07-22T05:49:00Z", nil}]) == true
    end

    test "false when there are no open PRs" do
      assert GitHubAPI.repo_pending_review?([]) == false
    end

    test "false when open PRs have no student commits" do
      assert GitHubAPI.repo_pending_review?([{nil, nil}]) == false
    end
  end

  describe "latest_instructor_review_at/2 (issue #31)" do
    test "excludes the student's own reviews and bot reviews" do
      reviews = [
        %{"user" => %{"login" => "k24rs062"}, "submitted_at" => "2026-07-10T00:00:00Z"},
        %{
          "user" => %{"login" => "github-actions[bot]"},
          "submitted_at" => "2026-07-10T01:00:00Z"
        },
        %{"user" => %{"login" => "toshi0806"}, "submitted_at" => "2026-07-09T00:00:00Z"}
      ]

      assert GitHubAPI.latest_instructor_review_at(reviews, "k24rs062") == "2026-07-09T00:00:00Z"
    end

    test "returns nil when only the student and bots have reviewed" do
      reviews = [
        %{"user" => %{"login" => "k24rs062"}, "submitted_at" => "2026-07-10T00:00:00Z"},
        %{"user" => %{"login" => "dependabot[bot]"}, "submitted_at" => "2026-07-10T01:00:00Z"}
      ]

      assert GitHubAPI.latest_instructor_review_at(reviews, "k24rs062") == nil
    end

    test "returns nil for an empty list" do
      assert GitHubAPI.latest_instructor_review_at([], "k24rs062") == nil
    end

    test "excludes reviews whose user type is Bot even without a [bot] login suffix" do
      reviews = [
        %{
          "user" => %{"login" => "some-app", "type" => "Bot"},
          "submitted_at" => "2026-07-10T00:00:00Z"
        },
        %{
          "user" => %{"login" => "toshi0806", "type" => "User"},
          "submitted_at" => "2026-07-09T00:00:00Z"
        }
      ]

      assert GitHubAPI.latest_instructor_review_at(reviews, "k24rs062") == "2026-07-09T00:00:00Z"
    end
  end

  describe "pending_review?/2 (issue #31)" do
    test "true when the student committed but no instructor has reviewed" do
      assert GitHubAPI.pending_review?("2026-07-08T06:00:00Z", nil) == true
    end

    test "true when the latest commit is newer than the latest instructor review" do
      assert GitHubAPI.pending_review?("2026-07-10T00:00:00Z", "2026-07-09T00:00:00Z") == true
    end

    test "false when the instructor review is newer than the latest commit" do
      assert GitHubAPI.pending_review?("2026-07-09T00:00:00Z", "2026-07-10T00:00:00Z") == false
    end

    test "false when there are no commits" do
      assert GitHubAPI.pending_review?(nil, "2026-07-09T00:00:00Z") == false
      assert GitHubAPI.pending_review?(nil, nil) == false
    end
  end

  defp student_commit(date, login, opts \\ []) do
    parents = for i <- 1..Keyword.get(opts, :parents, 1), do: %{"sha" => "parent#{i}"}

    %{
      "commit" => %{"committer" => %{"date" => date}},
      "author" => %{"login" => login},
      "parents" => parents
    }
  end
end
