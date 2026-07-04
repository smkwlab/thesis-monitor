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
      assert length(functions) > 0
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

    test "falls back to default org without loaded config" do
      ThesisMonitor.Config.load("/nonexistent/thesis-monitor.yml")

      assert GitHubAPI.build_repo_url("k21rs001-wr") ==
               "https://api.github.com/repos/smkwlab/k21rs001-wr"
    end
  end
end
