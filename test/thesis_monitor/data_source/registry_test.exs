defmodule ThesisMonitor.DataSource.RegistryTest do
  use ExUnit.Case, async: true

  alias ThesisMonitor.DataSource.Registry
  alias ThesisMonitor.Student

  @registry_json Jason.encode!(%{
                   "k21rs001-sotsuron" => %{
                     "student_id" => "k21rs001",
                     "repository_type" => "sotsuron",
                     "status" => "active",
                     "updated_at" => "2026-01-01T00:00:00Z"
                   }
                 })

  defp make_tmp_dir do
    dir = Path.join(System.tmp_dir(), "tm-registry-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # API モード用 config(キャッシュは既定で無効化し fetch_fn 呼び出しを観測可能にする)
  defp api_config(overrides \\ %{}) do
    cache_dir = make_tmp_dir()

    defaults = %{
      registry_repo: "testorg/thesis-student-registry",
      registry_dir: nil,
      cache_dir: cache_dir,
      cache_ttl: 0,
      github_org: "testorg"
    }

    config = Map.merge(defaults, overrides)
    fn key -> Map.get(config, key) end
  end

  describe "resolve_repo/1" do
    test "explicit registry_repo wins" do
      assert Registry.resolve_repo(api_config()) == "testorg/thesis-student-registry"
    end

    test "unset registry_repo resolves to the org convention repo" do
      config = api_config(%{registry_repo: nil})

      assert Registry.resolve_repo(config) == "testorg/thesis-student-registry"
    end

    test "empty registry_repo string falls back to the convention" do
      config = api_config(%{registry_repo: ""})

      assert Registry.resolve_repo(config) == "testorg/thesis-student-registry"
    end
  end

  describe "get_registry_students/2 (api mode)" do
    test "fetches data/registry.json and parses students" do
      fetch = fn "testorg/thesis-student-registry", "data/registry.json" ->
        {:ok, @registry_json}
      end

      assert {:ok, [student]} = Registry.get_registry_students(api_config(), fetch)

      assert %Student{id: "k21rs001", repo_name: "k21rs001-sotsuron", repo_type: "sotsuron"} =
               student
    end

    test "raises with actionable message when registry.json is missing" do
      fetch = fn _repo, "data/registry.json" -> {:error, :not_found} end

      assert_raise RuntimeError, ~r/registry/, fn ->
        Registry.get_registry_students(api_config(), fetch)
      end
    end

    test "raises with token guidance when the API returns unauthorized" do
      fetch = fn _repo, _path -> {:error, :unauthorized} end

      assert_raise RuntimeError, ~r/token/i, fn ->
        Registry.get_registry_students(api_config(), fetch)
      end
    end

    test "raises on other API errors instead of returning an empty list" do
      fetch = fn _repo, _path -> {:error, 500} end

      assert_raise RuntimeError, fn ->
        Registry.get_registry_students(api_config(), fetch)
      end
    end

    test "raises when the fetched registry content is invalid JSON (no silent zero)" do
      fetch = fn _repo, "data/registry.json" -> {:ok, "{broken json"} end

      assert_raise RuntimeError, ~r/JSON/i, fn ->
        Registry.get_registry_students(api_config(), fetch)
      end
    end

    test "raises when a cached registry entry is invalid JSON (corrupted cache)" do
      config = api_config(%{cache_ttl: 1800})

      # 1 回目で正常な内容をキャッシュさせた後、キャッシュファイルを破損させる
      fetch = fn _repo, "data/registry.json" -> {:ok, @registry_json} end
      assert {:ok, [_]} = Registry.get_registry_students(config, fetch)

      cache_dir = config.(:cache_dir)
      [cache_file] = File.ls!(cache_dir)
      File.write!(Path.join(cache_dir, cache_file), "{truncated")

      no_fetch = fn _repo, _path -> flunk("must hit cache") end

      assert_raise RuntimeError, ~r/JSON/i, fn ->
        Registry.get_registry_students(config, no_fetch)
      end
    end

    test "does not cache invalid JSON (next run refetches)" do
      config = api_config(%{cache_ttl: 1800})
      counter = :counters.new(1, [])

      fetch = fn _repo, "data/registry.json" ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1,
          do: {:ok, "{broken json"},
          else: {:ok, @registry_json}
      end

      assert_raise RuntimeError, ~r/JSON/i, fn ->
        Registry.get_registry_students(config, fetch)
      end

      assert {:ok, [_]} = Registry.get_registry_students(config, fetch)
      assert :counters.get(counter, 1) == 2
    end

    test "uses the cache within TTL (fetch called once)" do
      config = api_config(%{cache_ttl: 1800})
      counter = :counters.new(1, [])

      fetch = fn _repo, "data/registry.json" ->
        :counters.add(counter, 1, 1)
        {:ok, @registry_json}
      end

      assert {:ok, [_]} = Registry.get_registry_students(config, fetch)
      assert {:ok, [_]} = Registry.get_registry_students(config, fetch)
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "get_students/2 (protection status, api mode)" do
    test "fetches and parses the protection status file" do
      fetch = fn _repo, "data/protection-status/completed-protection.txt" ->
        {:ok, "Student: k21rs001 - Protected\n"}
      end

      assert {:ok, [%Student{id: "k21rs001", status: :protected}]} =
               Registry.get_students(api_config(), fetch)
    end

    test "missing protection file yields an empty list (file is optional)" do
      fetch = fn _repo, _path -> {:error, :not_found} end

      assert {:ok, []} = Registry.get_students(api_config(), fetch)
    end

    test "raises when the protection file fetch is unauthorized" do
      fetch = fn _repo, _path -> {:error, :unauthorized} end

      assert_raise RuntimeError, ~r/token/i, fn ->
        Registry.get_students(api_config(), fetch)
      end
    end
  end
end
