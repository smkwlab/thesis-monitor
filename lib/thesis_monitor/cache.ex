defmodule ThesisMonitor.Cache do
  @moduledoc """
  GitHub API 応答のファイルキャッシュ

  cache_dir 配下にキーごとの 1 ファイルとして保存し、cache_ttl 秒以内なら
  再取得せずに返す。キャッシュ I/O の失敗は fetch へフォールバックする
  （キャッシュは best-effort であり、失敗しても機能を止めない）。
  """

  alias ThesisMonitor.Config

  @doc """
  key のキャッシュが TTL 内ならその内容を返し、無ければ fetch_fn.() を実行して
  結果が {:ok, binary} のときだけキャッシュへ保存して返す。fetch の失敗は
  キャッシュしない（次回の呼び出しで再試行される）。
  """
  def get_or_fetch(key, fetch_fn, config_fn \\ &Config.get/1) do
    path = cache_path(key, config_fn)
    ttl = config_fn.(:cache_ttl) || 0

    case read_fresh(path, ttl) do
      {:ok, content} ->
        {:ok, content}

      :miss ->
        case fetch_fn.() do
          {:ok, content} = ok when is_binary(content) ->
            write(path, content)
            ok

          other ->
            other
        end
    end
  end

  defp cache_path(key, config_fn) do
    dir = Path.expand(config_fn.(:cache_dir) || "~/.cache/thesis-monitor")
    Path.join(dir, sanitize(key))
  end

  # キーに含まれる repo/path 区切りをフラットなファイル名に落とす
  defp sanitize(key), do: String.replace(key, ~r/[^A-Za-z0-9._-]/, "_")

  defp read_fresh(path, ttl) when is_integer(ttl) and ttl > 0 do
    now = System.system_time(:second)

    with {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix),
         true <- now - mtime < ttl,
         {:ok, content} <- File.read(path) do
      {:ok, content}
    else
      _ -> :miss
    end
  end

  defp read_fresh(_path, _ttl), do: :miss

  defp write(path, content) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, content)
    end

    :ok
  end
end
