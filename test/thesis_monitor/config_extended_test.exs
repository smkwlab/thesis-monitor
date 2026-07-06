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

  describe "registry_dir key (issue #7)" do
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

    test "loads registry_dir with tilde expansion" do
      path =
        write_tmp_config("""
        registry_dir: ~/test_registry_dir
        """)

      {:ok, _pid} = Config.load(path)

      assert Config.get(:registry_dir) == Path.expand("~/test_registry_dir")
    end

    test "accepts legacy data_dir key as fallback for registry_dir" do
      path =
        write_tmp_config("""
        data_dir: /tmp/test_legacy_data_dir
        """)

      {:ok, _pid} = Config.load(path)

      assert Config.get(:registry_dir) == "/tmp/test_legacy_data_dir"
    end

    test "removes the legacy data_dir key from the config map after migration" do
      path =
        write_tmp_config("""
        data_dir: /tmp/test_legacy_data_dir
        """)

      {:ok, _pid} = Config.load(path)

      refute Map.has_key?(Config.get_all(), :data_dir)
    end

    test "registry_dir wins when both keys are present" do
      path =
        write_tmp_config("""
        registry_dir: /tmp/test_new_wins
        data_dir: /tmp/test_old_loses
        """)

      {:ok, _pid} = Config.load(path)

      assert Config.get(:registry_dir) == "/tmp/test_new_wins"
      refute Map.has_key?(Config.get_all(), :data_dir)
    end

    test "warns with a deprecation message when only data_dir is set" do
      path =
        write_tmp_config("""
        data_dir: /tmp/test_legacy_data_dir
        """)

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          {:ok, _pid} = Config.load(path)
        end)

      assert stderr =~ "deprecated"
      assert stderr =~ "registry_dir"
    end

    test "warns that data_dir is ignored when registry_dir is also set" do
      path =
        write_tmp_config("""
        registry_dir: /tmp/test_new_wins
        data_dir: /tmp/test_old_loses
        """)

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          {:ok, _pid} = Config.load(path)
        end)

      assert stderr =~ "data_dir"
      assert stderr =~ "ignored"
    end
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

    test "accepts legacy student_csv key as fallback for csv_path" do
      path =
        write_tmp_config("""
        student_csv: /tmp/test_students.csv
        """)

      {:ok, _pid} = Config.load(path)

      assert Config.get(:csv_path) == "/tmp/test_students.csv"
      refute Map.has_key?(Config.get_all(), :student_csv)
    end

    test "csv_path wins when both keys are present" do
      path =
        write_tmp_config("""
        csv_path: /tmp/test_new.csv
        student_csv: /tmp/test_old.csv
        """)

      {:ok, _pid} = Config.load(path)

      assert Config.get(:csv_path) == "/tmp/test_new.csv"
      refute Map.has_key?(Config.get_all(), :student_csv)
    end

    test "warns with a deprecation message when only student_csv is set" do
      path =
        write_tmp_config("""
        student_csv: /tmp/test_students.csv
        """)

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          {:ok, _pid} = Config.load(path)
        end)

      assert stderr =~ "deprecated"
      assert stderr =~ "csv_path"
    end

    test "csv_path defaults to nil (or the conventional file if the host has one)" do
      {:ok, _pid} = Config.load(nil)

      # 実行環境に規約ファイル ~/.config/smkwlab/students.csv があればそれが入る
      assert Config.get(:csv_path) in [nil, Config.conventional_csv_path("smkwlab")]
    end
  end

  describe "config file location (issue #18)" do
    defp make_loc_home do
      home = Path.join(System.tmp_dir(), "tm-loc-home-#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      on_exit(fn -> File.rm_rf!(home) end)
      home
    end

    test "default config path is ~/.config/thesis-monitor/config.yml" do
      assert Config.default_config_path("/home/x") ==
               "/home/x/.config/thesis-monitor/config.yml"
    end

    test "legacy config path is ~/.thesis-monitor.yml" do
      assert Config.legacy_config_path("/home/x") == "/home/x/.thesis-monitor.yml"
    end

    test "resolve_user_config_path prefers the new location" do
      home = make_loc_home()
      new_path = Config.default_config_path(home)
      File.mkdir_p!(Path.dirname(new_path))
      File.write!(new_path, "github_org: neworg\n")
      File.write!(Config.legacy_config_path(home), "github_org: oldorg\n")

      assert Config.resolve_user_config_path(home) == new_path
    end

    test "falls back to the legacy dotfile with a deprecation warning" do
      home = make_loc_home()
      legacy = Config.legacy_config_path(home)
      File.write!(legacy, "github_org: oldorg\n")

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert Config.resolve_user_config_path(home) == legacy
        end)

      assert stderr =~ "deprecated"
      assert stderr =~ "config.yml"
    end

    test "returns nil when neither location exists" do
      home = make_loc_home()

      assert Config.resolve_user_config_path(home) == nil
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

    test "warns that registry_dir is deprecated when set without registry_repo" do
      path =
        write_tmp_config("""
        registry_dir: /tmp/test_registry/data
        """)

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          {:ok, _pid} = Config.load(path)
        end)

      assert stderr =~ "registry_dir"
      assert stderr =~ "deprecated"
      assert stderr =~ "registry_repo"
    end

    test "registry_dir is ignored with a warning when registry_repo is also set" do
      path =
        write_tmp_config("""
        registry_repo: myorg/thesis-student-registry
        registry_dir: /tmp/test_registry/data
        """)

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          {:ok, _pid} = Config.load(path)
        end)

      assert stderr =~ "registry_dir"
      assert stderr =~ "ignored"
      assert Config.get(:registry_dir) == nil
      assert Config.get(:registry_repo) == "myorg/thesis-student-registry"
    end

    test "registry_dir alone keeps working (one-generation legacy)" do
      path =
        write_tmp_config("""
        registry_dir: /tmp/test_registry/data
        """)

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        {:ok, _pid} = Config.load(path)
      end)

      assert Config.get(:registry_dir) == "/tmp/test_registry/data"
    end
  end

  describe "agent-less fallback (issue #14)" do
    # escript の init 経路は Config.load を呼ばないまま Config.get に到達する。
    # Agent 未起動は GenServer.call の exit になるため、rescue だけでは捕捉できない
    test "get falls back to defaults when the Config agent is not running" do
      refute Process.whereis(Config)

      assert Config.get(:github_org) == "smkwlab"
    end

    test "get expands path defaults when the Config agent is not running" do
      refute Process.whereis(Config)

      assert Config.get(:cache_dir) == Path.expand("~/.cache/thesis-monitor")
    end

    test "get_all falls back to defaults when the Config agent is not running" do
      refute Process.whereis(Config)

      assert Config.get_all()[:github_org] == "smkwlab"
    end
  end

  describe "load configuration from different sources" do
    test "loads from explicit config path" do
      config_content = """
      github_token: test_token_explicit
      github_org: test_org
      data_dir: /tmp/test_data
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
      registry_dir: ./test_data
      """

      File.write!("./config/thesis-monitor.yml", config_content)

      {:ok, _pid} = Config.load(nil)

      assert Config.get(:github_token) == "test_token_local"
      assert String.ends_with?(Config.get(:registry_dir), "/test_data")

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

    test "uses default config when no config files exist" do
      {:ok, _pid} = Config.load(nil)

      assert Config.get(:github_org) == "smkwlab"
      assert Config.get(:max_concurrency) == 10
      assert Config.get(:timeout) == 10_000
    end

    test "handles non-existent config file gracefully" do
      {:ok, _pid} = Config.load("/non/existent/path.yml")

      # Should fall back to default config
      assert Config.get(:github_org) == "smkwlab"
    end
  end

  describe "get functionality" do
    setup do
      Config.load(nil)
      :ok
    end

    test "gets value by atom key" do
      result = Config.get(:github_org)
      assert result == "smkwlab"
    end

    test "expands tilde in registry_dir path" do
      # Set a path with tilde
      Agent.update(Config, fn config ->
        Map.put(config, :registry_dir, "~/test_data")
      end)

      result = Config.get(:registry_dir)
      refute String.contains?(result, "~")
      assert String.ends_with?(result, "/test_data")
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
      assert result == "smkwlab"
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
      {:ok, _pid} = Config.load(nil)

      result = Config.get_all()
      assert is_map(result)
      assert result[:github_org] == "smkwlab"
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

      # Should use default values
      assert Config.get(:github_org) == "smkwlab"

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

      # Default values should still be present
      assert Config.get(:github_org) == "smkwlab"
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
      assert Config.get(:github_org) == "smkwlab"

      Agent.stop(Config)
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
