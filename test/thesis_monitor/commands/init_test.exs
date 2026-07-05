defmodule ThesisMonitor.Commands.InitTest do
  use ExUnit.Case, async: true

  alias ThesisMonitor.Commands.Init

  # Output 呼び出しをテストプロセスへ転送するスタブ
  defp output_stub do
    parent = self()

    %{
      puts: fn msg -> send(parent, {:out, :puts, msg}) end,
      info: fn msg -> send(parent, {:out, :info, msg}) end,
      success: fn msg -> send(parent, {:out, :success, msg}) end,
      warn: fn msg -> send(parent, {:out, :warn, msg}) end,
      error: fn msg -> send(parent, {:out, :error, msg}) end
    }
  end

  # 全チェック成功の gh スタブ
  defp gh_ok_stub do
    fn
      ["auth", "status" | _] -> {:ok, "Logged in"}
      ["api" | _] -> {:ok, "{}"}
      args -> flunk("unexpected gh invocation: #{inspect(args)}")
    end
  end

  defp tmp_path(prefix) do
    Path.join(
      System.tmp_dir!(),
      "#{prefix}_#{System.unique_integer([:positive])}"
    )
  end

  defp make_registry_checkout(prefix) do
    dir = tmp_path(prefix)
    File.mkdir_p!(Path.join(dir, "data"))
    File.write!(Path.join(dir, "data/registry.json"), "{}")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp collect_output(kind) do
    receive do
      {:out, ^kind, msg} -> [msg | collect_output(kind)]
    after
      0 -> []
    end
  end

  describe "run/3 config generation" do
    test "writes a config file with registry_dir, org, and cache_dir" do
      checkout = make_registry_checkout("init_checkout")
      config = tmp_path("init_config") <> ".yml"
      on_exit(fn -> File.rm(config) end)

      opts = [config: config, registry_dir: Path.join(checkout, "data"), org: "smkwlab"]

      assert {:ok, ^config} = Init.run([], opts, %{output: output_stub(), gh: gh_ok_stub()})

      content = File.read!(config)
      assert content =~ "github_org: smkwlab"
      assert content =~ "registry_dir: #{Path.join(checkout, "data")}"
      assert content =~ "cache_dir: ~/.cache/thesis-monitor"
    end

    test "refuses to overwrite an existing config without --force" do
      checkout = make_registry_checkout("init_checkout")
      config = tmp_path("init_config") <> ".yml"
      File.write!(config, "keep: me\n")
      on_exit(fn -> File.rm(config) end)

      opts = [config: config, registry_dir: Path.join(checkout, "data")]

      assert {:error, :config_exists} =
               Init.run([], opts, %{output: output_stub(), gh: gh_ok_stub()})

      assert File.read!(config) == "keep: me\n"
      assert Enum.any?(collect_output(:error), &(&1 =~ "--force"))
    end

    test "overwrites an existing config with --force" do
      checkout = make_registry_checkout("init_checkout")
      config = tmp_path("init_config") <> ".yml"
      File.write!(config, "keep: me\n")
      on_exit(fn -> File.rm(config) end)

      opts = [config: config, registry_dir: Path.join(checkout, "data"), force: true]

      assert {:ok, ^config} = Init.run([], opts, %{output: output_stub(), gh: gh_ok_stub()})
      assert File.read!(config) =~ "registry_dir:"
    end
  end

  describe "run/3 registry checkout resolution" do
    test "uses an existing checkout without cloning" do
      checkout = make_registry_checkout("init_existing")
      config = tmp_path("init_config") <> ".yml"
      on_exit(fn -> File.rm(config) end)

      gh = fn
        ["repo", "clone" | _] -> flunk("must not clone when the checkout already exists")
        args -> gh_ok_stub().(args)
      end

      opts = [config: config, clone_to: checkout]

      assert {:ok, _} = Init.run([], opts, %{output: output_stub(), gh: gh})
      assert File.read!(config) =~ "registry_dir: #{Path.join(checkout, "data")}"
    end

    test "clones the registry repo when no checkout exists" do
      clone_to = tmp_path("init_clone")
      config = tmp_path("init_config") <> ".yml"
      on_exit(fn -> File.rm_rf!(clone_to) end)
      on_exit(fn -> File.rm(config) end)

      gh = fn
        ["repo", "clone", "smkwlab/thesis-student-registry", ^clone_to] ->
          File.mkdir_p!(Path.join(clone_to, "data"))
          File.write!(Path.join(clone_to, "data/registry.json"), "{}")
          {:ok, ""}

        args ->
          gh_ok_stub().(args)
      end

      opts = [config: config, clone_to: clone_to]

      assert {:ok, _} = Init.run([], opts, %{output: output_stub(), gh: gh})
      assert File.read!(config) =~ "registry_dir: #{Path.join(clone_to, "data")}"
    end

    test "points to registry-manager init when the repo is unavailable" do
      clone_to = tmp_path("init_missing")
      config = tmp_path("init_config") <> ".yml"

      gh = fn
        ["repo", "clone" | _] -> {:error, "GraphQL: Could not resolve to a Repository"}
        args -> gh_ok_stub().(args)
      end

      opts = [config: config, clone_to: clone_to]

      assert {:error, :registry_repo_unavailable} =
               Init.run([], opts, %{output: output_stub(), gh: gh})

      refute File.exists?(config)
      assert Enum.any?(collect_output(:error), &(&1 =~ "registry-manager"))
    end
  end

  describe "run/3 --test sandbox mode" do
    test "defaults to the test registry and a separate cache dir" do
      clone_to = tmp_path("init_test_clone")
      config = tmp_path("init_config") <> ".yml"
      on_exit(fn -> File.rm_rf!(clone_to) end)
      on_exit(fn -> File.rm(config) end)

      gh = fn
        ["repo", "clone", "smkwlab/thesis-student-registry-test", ^clone_to] ->
          File.mkdir_p!(Path.join(clone_to, "data"))
          File.write!(Path.join(clone_to, "data/registry.json"), "{}")
          {:ok, ""}

        args ->
          gh_ok_stub().(args)
      end

      opts = [config: config, clone_to: clone_to, test: true]

      assert {:ok, _} = Init.run([], opts, %{output: output_stub(), gh: gh})

      content = File.read!(config)
      assert content =~ "cache_dir: ~/.cache/thesis-monitor-test"
    end
  end

  describe "run/3 doctor checks" do
    test "reports failing gh auth with a remedy" do
      checkout = make_registry_checkout("init_doctor")
      config = tmp_path("init_config") <> ".yml"
      on_exit(fn -> File.rm(config) end)

      gh = fn
        ["auth", "status" | _] -> {:error, "You are not logged into any GitHub hosts"}
        args -> gh_ok_stub().(args)
      end

      opts = [config: config, registry_dir: Path.join(checkout, "data")]

      assert {:ok, _} = Init.run([], opts, %{output: output_stub(), gh: gh})
      assert Enum.any?(collect_output(:warn), &(&1 =~ "gh auth login"))
    end

    test "warns when the registry file is missing from registry_dir" do
      dir = tmp_path("init_empty_dir")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      config = tmp_path("init_config") <> ".yml"
      on_exit(fn -> File.rm(config) end)

      opts = [config: config, registry_dir: dir]

      assert {:ok, _} = Init.run([], opts, %{output: output_stub(), gh: gh_ok_stub()})
      assert Enum.any?(collect_output(:warn), &(&1 =~ "registry.json"))
    end
  end
end
