defmodule ThesisMonitor.DataSourceIntegrationTest do
  # Config（名前付き Agent）を実際に load して本物の DataSource.get_all_students/0 を
  # 駆動する統合テスト。ネットワークは使わない: Registry のキャッシュ
  # （cache_dir 配下、キー "<repo>:<path>"）を事前に投入して API 呼び出しを回避する。
  use ExUnit.Case, async: false

  alias ThesisMonitor.{Cache, Config, DataSource}

  @repo "cachedorg/thesis-student-registry"

  setup do
    if Process.whereis(Config) do
      try do
        Agent.stop(Config)
      catch
        :exit, _ -> :ok
      end
    end

    cache_dir =
      Path.join(System.tmp_dir(), "tm-integration-#{System.unique_integer([:positive])}")

    config_path = Path.join(cache_dir, "config.yml")
    File.mkdir_p!(cache_dir)

    File.write!(config_path, """
    github_org: cachedorg
    registry_repo: #{@repo}
    cache_dir: #{cache_dir}
    cache_ttl: 3600
    """)

    on_exit(fn -> File.rm_rf!(cache_dir) end)

    {:ok, _pid} = Config.load(config_path)
    %{cache_dir: cache_dir}
  end

  defp prime_cache(key, content) do
    {:ok, ^content} = Cache.get_or_fetch(key, fn -> {:ok, content} end, &Config.get/1)
  end

  test "get_all_students reads students through the API-mode pipeline" do
    prime_cache("#{@repo}:data/protection-status/completed-protection.txt", "")

    prime_cache(
      "#{@repo}:data/registry.json",
      Jason.encode!(%{
        "k21rs001-sotsuron" => %{"student_id" => "k21rs001", "repository_type" => "sotsuron"}
      })
    )

    assert {:ok, [student]} = DataSource.get_all_students()
    assert student.id == "k21rs001"
  end

  test "a Registry RuntimeError propagates out of get_all_students (no silent empty list)" do
    prime_cache("#{@repo}:data/protection-status/completed-protection.txt", "")
    prime_cache("#{@repo}:data/registry.json", "{corrupted json")

    # get_all_students の with/else が例外を registry_only_students() に
    # 畳み込まないこと（空リスト沈黙の防止、issue #14 の中核保証）
    assert_raise RuntimeError, ~r/JSON/i, fn ->
      DataSource.get_all_students()
    end
  end
end
