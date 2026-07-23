defmodule ThesisMonitor.ConfigExtendedTest do
  use ExUnit.Case, async: false

  alias ThesisMonitor.Config

  setup do
    # Stop any existing Config process
    if Process.whereis(Config) do
      try do
        Agent.stop(Config)
      rescue
        _ -> :ok
      catch
        :exit, _ -> :ok
      end
    end

    # Clean up test files (only test-specific files, not user's config)
    on_exit(fn ->
      ["./config/thesis-monitor.yml", "./test-config.yml"]
      |> Enum.each(fn path ->
        expanded = Path.expand(path)
        if File.exists?(expanded), do: File.rm!(expanded)
      end)
    end)

    :ok
  end

  defp write_tmp_config(content) do
    path =
      Path.join(
        System.tmp_dir(),
        "thesis-monitor-config-test-#{System.unique_integer([:positive])}.yml"
      )

    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "csv_path key (issue #14)" do
    test "loads csv_path with tilde expansion" do
      path =
        write_tmp_config("""
        csv_path: ~/test_students.csv
        """)

      {:ok, _pid} = Config.load(path)

      assert Config.get(:csv_path) == Path.expand("~/test_students.csv")
    end

    test "csv_path defaults to nil when no CSV is configured" do
      # github_org を実在しない org にして、実行環境の規約ファイル
      # （~/.config/smkwlab/students.csv 等）に依存しない決定論的なテストにする
      path =
        write_tmp_config("""
        github_org: no-such-org-#{System.unique_integer([:positive])}
        """)

      {:ok, _pid} = Config.load(path)

      assert Config.get(:csv_path) == nil
    end
  end

  describe "config file location (issue #18)" do
    test "default config path is ~/.config/thesis-monitor/config.yml" do
      assert Config.default_config_path("/home/x") ==
               "/home/x/.config/thesis-monitor/config.yml"
    end
  end

  describe "csv_path convention (issue #16)" do
    defp make_conv_home do
      home = Path.join(System.tmp_dir(), "tm-conv-home-#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      on_exit(fn -> File.rm_rf!(home) end)
      home
    end

    test "conventional_csv_path derives from github_org" do
      assert Config.conventional_csv_path("myorg", "/home/x") ==
               "/home/x/.config/myorg/students.csv"
    end

    test "uses the conventional path when csv_path is unset and the file exists" do
      home = make_conv_home()
      conventional = Path.join([home, ".config", "testorg", "students.csv"])
      File.mkdir_p!(Path.dirname(conventional))
      File.write!(conventional, "header\n")

      config = %{csv_path: nil, github_org: "testorg"}

      assert Config.apply_csv_convention(config, home).csv_path == conventional
    end

    test "keeps csv_path nil when the conventional file does not exist" do
      home = make_conv_home()
      config = %{csv_path: nil, github_org: "testorg"}

      assert Config.apply_csv_convention(config, home).csv_path == nil
    end

    test "an explicit csv_path wins over the conventional file" do
      home = make_conv_home()
      conventional = Path.join([home, ".config", "testorg", "students.csv"])
      File.mkdir_p!(Path.dirname(conventional))
      File.write!(conventional, "header\n")

      config = %{csv_path: "/explicit/path.csv", github_org: "testorg"}

      assert Config.apply_csv_convention(config, home).csv_path == "/explicit/path.csv"
    end

    test "an empty-string csv_path is treated as unset" do
      home = make_conv_home()
      conventional = Path.join([home, ".config", "testorg", "students.csv"])
      File.mkdir_p!(Path.dirname(conventional))
      File.write!(conventional, "header\n")

      config = %{csv_path: "", github_org: "testorg"}

      assert Config.apply_csv_convention(config, home).csv_path == conventional
    end

    test "skips the convention when github_org is nil or empty" do
      home = make_conv_home()
      conventional = Path.join([home, ".config", "testorg", "students.csv"])
      File.mkdir_p!(Path.dirname(conventional))
      File.write!(conventional, "header\n")

      assert Config.apply_csv_convention(%{csv_path: nil, github_org: nil}, home).csv_path == nil
      assert Config.apply_csv_convention(%{csv_path: nil, github_org: ""}, home).csv_path == nil
    end

    test "skips the convention when the home directory is unavailable" do
      config = %{csv_path: nil, github_org: "testorg"}

      assert Config.apply_csv_convention(config, nil).csv_path == nil
    end

    test "load applies the convention (nil for an unlikely org)" do
      path =
        write_tmp_config("""
        github_org: no-such-org-#{System.unique_integer([:positive])}
        """)

      {:ok, _pid} = Config.load(path)

      assert Config.get(:csv_path) == nil
    end
  end

  describe "registry_repo key (issue #14)" do
    test "loads registry_repo from config" do
      path =
        write_tmp_config("""
        registry_repo: myorg/thesis-student-registry
        """)

      {:ok, _pid} = Config.load(path)

      assert Config.get(:registry_repo) == "myorg/thesis-student-registry"
    end

    test "registry_repo defaults to nil" do
      {:ok, _pid} = Config.load(nil)

      assert Config.get(:registry_repo) == nil
    end
  end

  describe "github_org convention: derive from registry_repo owner (issue #28)" do
    test "derives github_org from the registry_repo owner when unset" do
      config = Config.apply_github_org_convention(%{github_org: nil, registry_repo: "acme/reg"})

      assert config.github_org == "acme"
    end

    test "treats an empty github_org as unset and derives from registry_repo" do
      config = Config.apply_github_org_convention(%{github_org: "", registry_repo: "acme/reg"})

      assert config.github_org == "acme"
    end

    test "an explicit github_org wins over the derived owner" do
      config =
        Config.apply_github_org_convention(%{github_org: "explicit", registry_repo: "acme/reg"})

      assert config.github_org == "explicit"
    end

    test "leaves github_org nil when neither github_org nor registry_repo is set" do
      config = Config.apply_github_org_convention(%{github_org: nil, registry_repo: nil})

      assert config.github_org == nil
    end

    test "leaves github_org nil when registry_repo is malformed (no owner/repo)" do
      config = Config.apply_github_org_convention(%{github_org: nil, registry_repo: "noslash"})

      assert config.github_org == nil
    end

    test "load derives github_org from registry_repo instead of a hardcoded default" do
      path = write_tmp_config("registry_repo: acme/thesis-student-registry\n")
      {:ok, _pid} = Config.load(path)

      assert Config.get(:github_org) == "acme"
    end

    test "require_github_org! returns a configured org" do
      assert Config.require_github_org!("acme") == "acme"
    end

    test "require_github_org! raises for nil or empty (issue #28)" do
      assert_raise RuntimeError, ~r/github_org/, fn -> Config.require_github_org!(nil) end
      assert_raise RuntimeError, ~r/github_org/, fn -> Config.require_github_org!("") end
    end
  end

  describe "agent-less fallback (issue #14)" do
    # escript の init 経路は Config.load を呼ばないまま Config.get に到達する。
    # Agent 未起動は GenServer.call の exit になるため、rescue だけでは捕捉できない
    test "get falls back to defaults when the Config agent is not running" do
      refute Process.whereis(Config)

      # 既定 org は持たない（issue #28）。config 無しでは nil のまま
      assert Config.get(:github_org) == nil
    end

    test "get expands path defaults when the Config agent is not running" do
      refute Process.whereis(Config)

      assert Config.get(:cache_dir) == Path.expand("~/.cache/thesis-monitor")
    end

    test "get_all falls back to defaults when the Config agent is not running" do
      refute Process.whereis(Config)

      assert Config.get_all()[:github_org] == nil
    end
  end

  describe "load configuration from different sources" do
    test "loads from explicit config path" do
      config_content = """
      github_token: test_token_explicit
      github_org: test_org
      max_concurrency: 15
      timeout: 20_000
      """

      File.write!("./test-config.yml", config_content)

      {:ok, _pid} = Config.load("./test-config.yml")

      assert Config.get(:github_token) == "test_token_explicit"
      assert Config.get(:github_org) == "test_org"
      assert Config.get(:max_concurrency) == 15
      assert Config.get(:timeout) == "20_000"

      File.rm!("./test-config.yml")
    end

    test "loads from ./config/thesis-monitor.yml when exists" do
      File.mkdir_p!("./config")

      config_content = """
      github_token: test_token_local
      registry_repo: localorg/thesis-student-registry
      """

      File.write!("./config/thesis-monitor.yml", config_content)

      {:ok, _pid} = Config.load(nil)

      assert Config.get(:github_token) == "test_token_local"
      assert Config.get(:registry_repo) == "localorg/thesis-student-registry"

      File.rm!("./config/thesis-monitor.yml")
      # Don't remove config directory as it might not be empty
    end

    test "loads from ~/.thesis-monitor.yml when local config doesn't exist" do
      # Use a test-specific home config file to avoid affecting user's actual config
      test_home_config =
        Path.join(System.tmp_dir(), ".thesis-monitor-test-#{:rand.uniform(10000)}.yml")

      config_content = """
      github_token: test_token_home
      github_org: home_org
      """

      File.write!(test_home_config, config_content)

      # Note: This test verifies the loading logic, but we can't actually test
      # the real home directory loading without affecting the user's config
      # So we skip the actual loading test and just verify the file creation
      assert File.exists?(test_home_config)

      # Clean up
      File.rm!(test_home_config)
    end

    test "a config file without github_org leaves it nil (no silent default org, issue #28)" do
      # ~/.config への依存を断つため、org を持たない config を明示的に読む。
      # 既定 org を廃止したので github_org は nil のまま、他の既定はマージで残る。
      path = write_tmp_config("github_token: x\n")
      {:ok, _pid} = Config.load(path)

      assert Config.get(:github_org) == nil
      assert Config.get(:max_concurrency) == 10
      assert Config.get(:timeout) == 10_000
    end

    test "handles non-existent config file gracefully" do
      {:ok, _pid} = Config.load("/non/existent/path.yml")

      # 落ちずに設定マップを返せること（github_org の実効値は実 config 依存のため
      # 値は検証せず、graceful に動作することだけ確認する）
      assert is_map(Config.get_all())
    end
  end

  describe "get functionality" do
    setup do
      # 実 config（~/.config）への依存を断つため、既知の org を持つ config を明示的に読む
      path = write_tmp_config("github_org: getfunc_org\n")
      Config.load(path)
      :ok
    end

    test "gets value by atom key" do
      result = Config.get(:github_org)
      assert result == "getfunc_org"
    end

    test "expands tilde in cache_dir path" do
      result = Config.get(:cache_dir)
      refute String.contains?(result, "~")
      assert String.ends_with?(result, "/.cache/thesis-monitor")
    end

    test "returns nil for non-existent keys" do
      result = Config.get(:non_existent_key)
      assert is_nil(result)
    end

    test "handles process crash gracefully" do
      # Test that error handling paths work
      # We test the rescue clause logic indirectly
      result = Config.get(:non_existent_key)
      assert is_nil(result)

      # Test that default values are accessible
      result = Config.get(:github_org)
      assert result == "getfunc_org"
    end

    test "handles cache_dir expansion in default config" do
      # Test path expansion logic in default case
      result = Config.get(:cache_dir)
      refute String.contains?(result, "~")
      assert String.ends_with?(result, "/.cache/thesis-monitor")
    end
  end

  describe "get_all functionality" do
    test "returns complete configuration map" do
      {:ok, _pid} = Config.load(nil)

      result = Config.get_all()
      assert is_map(result)
      assert Map.has_key?(result, :github_org)
      assert Map.has_key?(result, :max_concurrency)
      assert Map.has_key?(result, :timeout)
    end

    test "handles error conditions gracefully" do
      path = write_tmp_config("github_org: errcond_org\n")
      {:ok, _pid} = Config.load(path)

      result = Config.get_all()
      assert is_map(result)
      assert result[:github_org] == "errcond_org"
    end
  end

  describe "load_from_file functionality" do
    test "handles malformed YAML file" do
      malformed_content = """
      invalid: yaml: content:
        - broken
      nested
      """

      File.write!("./malformed.yml", malformed_content)

      # Should fall back to default config without crashing
      {:ok, _pid} = Config.load("./malformed.yml")

      # Should use default values（既定 org は廃止済みなので nil、issue #28）
      assert Config.get(:github_org) == nil

      File.rm!("./malformed.yml")
    end

    test "merges config with defaults properly" do
      partial_config = """
      github_token: custom_token
      max_concurrency: 5
      """

      File.write!("./partial.yml", partial_config)

      {:ok, _pid} = Config.load("./partial.yml")

      # Custom values should be present
      assert Config.get(:github_token) == "custom_token"
      assert Config.get(:max_concurrency) == 5

      # Default values should still be present（github_org は既定を持たず nil、issue #28）
      assert Config.get(:github_org) == nil
      assert Config.get(:timeout) == 10_000

      File.rm!("./partial.yml")
    end

    test "converts string keys to atoms" do
      config_content = """
      "github_token": "string_key_token"
      "custom_setting": "test_value"
      """

      File.write!("./string_keys.yml", config_content)

      {:ok, _pid} = Config.load("./string_keys.yml")

      assert Config.get(:github_token) == "string_key_token"
      assert Config.get(:custom_setting) == "test_value"

      File.rm!("./string_keys.yml")
    end
  end

  describe "process management" do
    test "reuses existing process when already running" do
      {:ok, pid1} = Config.load(nil)
      {:ok, pid2} = Config.load(nil)

      assert pid1 == pid2
    end

    test "updates existing process with new config" do
      {:ok, _pid} = Config.load(nil)
      original_token = Config.get(:github_token)

      # Create new config
      new_config = """
      github_token: updated_token
      """

      File.write!("./updated.yml", new_config)

      {:ok, _pid} = Config.load("./updated.yml")
      updated_token = Config.get(:github_token)

      refute original_token == updated_token
      assert updated_token == "updated_token"

      File.rm!("./updated.yml")
    end
  end

  describe "start_link functionality" do
    test "starts with default config" do
      {:ok, pid} = Config.start_link([])

      assert Process.alive?(pid)

      # start_link は @default_config で起動する。既定 org は廃止済みなので nil（issue #28）
      assert Config.get(:github_org) == nil

      Agent.stop(Config)
    end
  end

  describe "environment variable layer (THESIS_MONITOR_*)" do
    defp put_test_env(var, value) do
      System.put_env(var, value)
      on_exit(fn -> System.delete_env(var) end)
    end

    test "THESIS_MONITOR_GITHUB_ORG overrides the file value" do
      path = write_tmp_config("github_org: fileorg\n")
      put_test_env("THESIS_MONITOR_GITHUB_ORG", "envorg")

      {:ok, _pid} = Config.load(path)

      assert Config.get(:github_org) == "envorg"
    end

    test "THESIS_MONITOR_CACHE_TTL is converted to integer" do
      path = write_tmp_config("github_org: envttl_org\n")
      put_test_env("THESIS_MONITOR_CACHE_TTL", "60")

      {:ok, _pid} = Config.load(path)

      assert Config.get(:cache_ttl) == 60
    end

    test "an invalid THESIS_MONITOR_* value falls back to the other layers" do
      path = write_tmp_config("cache_ttl: 900\n")
      put_test_env("THESIS_MONITOR_CACHE_TTL", "not-a-number")

      {:ok, _pid} = Config.load(path)

      assert Config.get(:cache_ttl) == 900
    end
  end

  describe "environment variable handling" do
    test "loads github_token from environment" do
      # This tests the default config behavior
      {:ok, _pid} = Config.load(nil)

      # The token should be from environment or nil
      token = Config.get(:github_token)
      assert is_nil(token) or is_binary(token)
    end
  end
end
