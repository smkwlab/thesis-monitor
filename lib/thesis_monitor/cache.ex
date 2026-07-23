defmodule ThesisMonitor.Cache do
  @moduledoc """
  GitHub API 応答のファイルキャッシュ

  機構は `ToolKit.Cache` に委譲し、本モジュールは thesis-monitor の設定
  （cache_dir / cache_ttl）を `ToolKit.Cache` のオプションへ橋渡しするだけの
  薄い層。cache_dir 配下にキーごとの 1 ファイルとして保存し、cache_ttl 秒以内なら
  再取得せずに返す。ttl <= 0（`--no-cache`）は常にミス。キャッシュ I/O の失敗は
  fetch へフォールバックする（キャッシュは best-effort であり、失敗しても機能を
  止めない）。
  """

  alias ThesisMonitor.Config

  @default_cache_dir "~/.cache/thesis-monitor"

  @doc """
  key のキャッシュが TTL 内ならその内容を返し、無ければ fetch_fn.() を実行して
  結果が {:ok, binary} のときだけキャッシュへ保存して返す。fetch の失敗は
  キャッシュしない（次回の呼び出しで再試行される）。
  """
  def get_or_fetch(key, fetch_fn, config_fn \\ &Config.get/1) do
    ToolKit.Cache.get_or_fetch(key, fetch_fn, cache_opts(config_fn))
  end

  # thesis-monitor の設定を ToolKit.Cache のオプションへ橋渡しする。
  # cache_dir 未設定時は従来どおり ~/.cache/thesis-monitor を既定にし、
  # cache_ttl 未設定時は 0（常にミス = --no-cache 相当）へフォールバックする。
  # category "" は cache_dir 直下へフラットに保存する従来のレイアウト
  # （<cache_dir>/<key>）を維持し、サブディレクトリを作らない
  # （Path.join(dir, "") == dir）。
  defp cache_opts(config_fn) do
    [
      cache_dir: Path.expand(config_fn.(:cache_dir) || @default_cache_dir),
      category: "",
      ttl: config_fn.(:cache_ttl) || 0
    ]
  end
end
