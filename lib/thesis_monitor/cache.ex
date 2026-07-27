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
  # PR ステータス（pr-stats）用のキャッシュカテゴリ。レジストリキャッシュ
  # （category ""）とはサブディレクトリで分離する（rm の "pr-status" と同じ命名）。
  @pr_cache_category "pr-status"

  @doc """
  key のキャッシュが TTL 内ならその内容を返し、無ければ fetch_fn.() を実行して
  結果が {:ok, binary} のときだけキャッシュへ保存して返す。fetch の失敗は
  キャッシュしない（次回の呼び出しで再試行される）。
  """
  def get_or_fetch(key, fetch_fn, config_fn \\ &Config.get/1) do
    ToolKit.Cache.get_or_fetch(key, fetch_fn, cache_opts(config_fn))
  end

  @doc """
  pr-stats 用のキャッシュ付き取得（category "pr-status"）。

  `no_cache?` が真ならキャッシュを読まず fetch_fn.() をそのまま実行する
  （`--no-cache` のバイパス）。それ以外は get_or_fetch と同じく TTL 内の
  キャッシュを返し、無ければ fetch して結果（{:ok, binary}）を保存する。
  """
  def pr_get_or_fetch(key, fetch_fn, no_cache?, config_fn \\ &Config.get/1)

  def pr_get_or_fetch(_key, fetch_fn, true, _config_fn), do: fetch_fn.()

  def pr_get_or_fetch(key, fetch_fn, false, config_fn) do
    ToolKit.Cache.get_or_fetch(key, fetch_fn, pr_cache_opts(config_fn))
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

  # pr-stats 用は category "pr-status" のサブディレクトリへ保存する以外は
  # cache_opts と同じ設定（cache_dir / ttl は tm の設定から橋渡し）。
  defp pr_cache_opts(config_fn) do
    [
      cache_dir: Path.expand(config_fn.(:cache_dir) || @default_cache_dir),
      category: @pr_cache_category,
      ttl: config_fn.(:cache_ttl) || 0
    ]
  end
end
