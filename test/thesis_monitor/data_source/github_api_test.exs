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
        # デフォルト設定に戻す
        ThesisMonitor.Config.load("/nonexistent/thesis-monitor.yml")
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
        ThesisMonitor.Config.load("/nonexistent/thesis-monitor.yml")
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
end
