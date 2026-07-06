defmodule ThesisMonitor.CacheTest do
  use ExUnit.Case, async: true

  alias ThesisMonitor.Cache

  defp make_cache_dir do
    dir = Path.join(System.tmp_dir(), "tm-cache-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp config_fn(dir, ttl) do
    fn
      :cache_dir -> dir
      :cache_ttl -> ttl
      _ -> nil
    end
  end

  test "miss fetches the value and stores it" do
    dir = make_cache_dir()
    counter = :counters.new(1, [])

    fetch = fn ->
      :counters.add(counter, 1, 1)
      {:ok, "payload"}
    end

    assert {:ok, "payload"} = Cache.get_or_fetch("key1", fetch, config_fn(dir, 1800))
    assert :counters.get(counter, 1) == 1
    assert [_file] = File.ls!(dir)
  end

  test "hit within TTL does not call fetch again" do
    dir = make_cache_dir()
    config = config_fn(dir, 1800)

    assert {:ok, "payload"} = Cache.get_or_fetch("key1", fn -> {:ok, "payload"} end, config)

    fetch = fn -> flunk("fetch must not be called on cache hit") end
    assert {:ok, "payload"} = Cache.get_or_fetch("key1", fetch, config)
  end

  test "expired entry refetches (ttl 0 disables caching)" do
    dir = make_cache_dir()
    config = config_fn(dir, 0)
    counter = :counters.new(1, [])

    fetch = fn ->
      :counters.add(counter, 1, 1)
      {:ok, "v#{:counters.get(counter, 1)}"}
    end

    assert {:ok, "v1"} = Cache.get_or_fetch("key1", fetch, config)
    assert {:ok, "v2"} = Cache.get_or_fetch("key1", fetch, config)
  end

  test "fetch error is returned and not cached" do
    dir = make_cache_dir()
    config = config_fn(dir, 1800)

    assert {:error, :boom} = Cache.get_or_fetch("key1", fn -> {:error, :boom} end, config)
    assert {:ok, "ok"} = Cache.get_or_fetch("key1", fn -> {:ok, "ok"} end, config)
  end

  test "different keys use different cache entries" do
    dir = make_cache_dir()
    config = config_fn(dir, 1800)

    assert {:ok, "a"} = Cache.get_or_fetch("key-a", fn -> {:ok, "a"} end, config)
    assert {:ok, "b"} = Cache.get_or_fetch("key-b", fn -> {:ok, "b"} end, config)
    assert {:ok, "a"} = Cache.get_or_fetch("key-a", fn -> flunk("must hit cache") end, config)
  end

  test "keys with repo/path separators are sanitized into flat filenames" do
    dir = make_cache_dir()
    config = config_fn(dir, 1800)

    key = "smkwlab/thesis-student-registry:data/registry.json"
    assert {:ok, "content"} = Cache.get_or_fetch(key, fn -> {:ok, "content"} end, config)

    # キャッシュファイルは cache_dir 直下に 1 つだけでき、サブディレクトリを作らない
    assert [file] = File.ls!(dir)
    refute String.contains?(file, "/")
    assert {:ok, "content"} = Cache.get_or_fetch(key, fn -> flunk("must hit cache") end, config)
  end

  test "missing cache_dir is created on demand" do
    dir = Path.join(make_cache_dir(), "nested/sub")
    config = config_fn(dir, 1800)

    assert {:ok, "x"} = Cache.get_or_fetch("key1", fn -> {:ok, "x"} end, config)
    assert {:ok, "x"} = Cache.get_or_fetch("key1", fn -> flunk("must hit cache") end, config)
  end
end
