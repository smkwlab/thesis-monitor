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

  # 全チェック成功の gh スタブ（clone は API 読み化で廃止済み: 呼ばれたら失敗）
  defp gh_ok_stub do
    fn
      ["repo", "clone" | _] -> flunk("init must not clone (API-read mode, issue #14)")
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

  describe "run/3 config generation (API mode)" do
    test "writes org and cache_dir without cloning; convention registry_repo is a comment" do
      config = tmp_path("init_config") <> ".yml"
      on_exit(fn -> File.rm(config) end)

      opts = [config: config, org: "smkwlab"]

      assert {:ok, ^config} = Init.run([], opts, %{output: output_stub(), gh: gh_ok_stub()})

      content = File.read!(config)
      assert content =~ "github_org: smkwlab"

      # 規約値と一致する registry_repo はコメントで書く（実効値は規約導出に任せ、
      # 生成ファイルをドリフト源にしない。issue #16）
      assert content =~ ~r/^# registry_repo: smkwlab\/thesis-student-registry/m
      refute content =~ ~r/^registry_repo:/m
      assert content =~ "cache_dir: ~/.cache/thesis-monitor"
      refute content =~ ~r/^registry_dir:/m
    end

    test "includes a commented csv_path hint mentioning the conventional path" do
      config = tmp_path("init_config") <> ".yml"
      on_exit(fn -> File.rm(config) end)

      assert {:ok, _} =
               Init.run([], [config: config], %{output: output_stub(), gh: gh_ok_stub()})

      content = File.read!(config)
      assert content =~ "# csv_path:"
      assert content =~ "students.csv"
    end

    test "derives the commented registry_repo from --org by convention" do
      config = tmp_path("init_config") <> ".yml"
      on_exit(fn -> File.rm(config) end)

      opts = [config: config, org: "myorg"]

      assert {:ok, _} = Init.run([], opts, %{output: output_stub(), gh: gh_ok_stub()})

      content = File.read!(config)
      assert content =~ "github_org: myorg"
      assert content =~ ~r/^# registry_repo: myorg\/thesis-student-registry/m
      refute content =~ ~r/^registry_repo:/m
    end

    test "honors an explicit --registry-repo override as an active line" do
      config = tmp_path("init_config") <> ".yml"
      on_exit(fn -> File.rm(config) end)

      opts = [config: config, registry_repo: "otherorg/custom-registry"]

      assert {:ok, _} = Init.run([], opts, %{output: output_stub(), gh: gh_ok_stub()})
      assert File.read!(config) =~ ~r/^registry_repo: otherorg\/custom-registry/m
    end

    test "refuses to overwrite an existing config without --force" do
      config = tmp_path("init_config") <> ".yml"
      File.write!(config, "keep: me\n")
      on_exit(fn -> File.rm(config) end)

      assert {:error, :config_exists} =
               Init.run([], [config: config], %{output: output_stub(), gh: gh_ok_stub()})

      assert File.read!(config) == "keep: me\n"
      assert Enum.any?(collect_output(:error), &(&1 =~ "--force"))
    end

    test "overwrites an existing config with --force" do
      config = tmp_path("init_config") <> ".yml"
      File.write!(config, "keep: me\n")
      on_exit(fn -> File.rm(config) end)

      opts = [config: config, force: true]

      assert {:ok, ^config} = Init.run([], opts, %{output: output_stub(), gh: gh_ok_stub()})
      assert File.read!(config) =~ "registry_repo:"
    end
  end

  describe "run/3 legacy local mode (--registry-dir)" do
    test "writes registry_dir instead of registry_repo" do
      checkout = make_registry_checkout("init_local")
      config = tmp_path("init_config") <> ".yml"
      on_exit(fn -> File.rm(config) end)

      opts = [config: config, registry_dir: Path.join(checkout, "data")]

      assert {:ok, _} = Init.run([], opts, %{output: output_stub(), gh: gh_ok_stub()})

      content = File.read!(config)
      assert content =~ "registry_dir: #{Path.join(checkout, "data")}"
      refute content =~ "registry_repo:"
    end

    test "fails when the given registry_dir does not exist" do
      config = tmp_path("init_config") <> ".yml"

      opts = [config: config, registry_dir: "/nonexistent/registry/data"]

      assert {:error, :registry_dir_not_found} =
               Init.run([], opts, %{output: output_stub(), gh: gh_ok_stub()})

      refute File.exists?(config)
    end
  end

  describe "run/3 --test sandbox mode" do
    test "uses the test registry repo and a separate cache dir" do
      config = tmp_path("init_config") <> ".yml"
      on_exit(fn -> File.rm(config) end)

      opts = [config: config, test: true]

      assert {:ok, _} = Init.run([], opts, %{output: output_stub(), gh: gh_ok_stub()})

      content = File.read!(config)
      # テスト repo は規約値（<org>/thesis-student-registry）と異なるため
      # 有効行として書かれなければならない
      assert content =~ ~r/^registry_repo: smkwlab\/thesis-student-registry-test/m
      assert content =~ "cache_dir: ~/.cache/thesis-monitor-test"
    end
  end

  describe "run/3 doctor checks" do
    test "verifies registry access via the contents API" do
      config = tmp_path("init_config") <> ".yml"
      on_exit(fn -> File.rm(config) end)
      parent = self()

      gh = fn
        ["api", "repos/smkwlab/thesis-student-registry/contents/data/registry.json" | _] ->
          send(parent, :registry_api_checked)
          {:ok, "{}"}

        args ->
          gh_ok_stub().(args)
      end

      assert {:ok, _} = Init.run([], [config: config], %{output: output_stub(), gh: gh})
      assert_received :registry_api_checked
      assert Enum.any?(collect_output(:success), &(&1 =~ "registry"))
    end

    test "warns with a legacy note when only repositories.json exists" do
      config = tmp_path("init_config") <> ".yml"
      on_exit(fn -> File.rm(config) end)

      gh = fn
        ["api", "repos/" <> rest | _] ->
          cond do
            String.ends_with?(rest, "data/registry.json") -> {:error, "HTTP 404"}
            String.ends_with?(rest, "data/repositories.json") -> {:ok, "{}"}
            true -> {:ok, "{}"}
          end

        args ->
          gh_ok_stub().(args)
      end

      assert {:ok, _} = Init.run([], [config: config], %{output: output_stub(), gh: gh})
      assert Enum.any?(collect_output(:warn), &(&1 =~ "repositories.json"))
    end

    test "points to registry-manager init when the registry is unreachable" do
      config = tmp_path("init_config") <> ".yml"
      on_exit(fn -> File.rm(config) end)

      gh = fn
        ["api", "repos/" <> rest | _] ->
          if String.contains?(rest, "/contents/"),
            do: {:error, "HTTP 404"},
            else: {:ok, "{}"}

        args ->
          gh_ok_stub().(args)
      end

      assert {:ok, _} = Init.run([], [config: config], %{output: output_stub(), gh: gh})
      assert Enum.any?(collect_output(:warn), &(&1 =~ "registry-manager"))
    end

    test "reports failing gh auth with a remedy" do
      config = tmp_path("init_config") <> ".yml"
      on_exit(fn -> File.rm(config) end)

      gh = fn
        ["auth", "status" | _] -> {:error, "You are not logged into any GitHub hosts"}
        args -> gh_ok_stub().(args)
      end

      assert {:ok, _} = Init.run([], [config: config], %{output: output_stub(), gh: gh})
      assert Enum.any?(collect_output(:warn), &(&1 =~ "gh auth login"))
    end

    test "warns when the registry file is missing from registry_dir (local mode)" do
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
