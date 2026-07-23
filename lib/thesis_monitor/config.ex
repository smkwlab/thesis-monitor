defmodule ThesisMonitor.Config do
  @moduledoc """
  設定管理モジュール
  """

  use Agent

  alias ToolKit.Config.Layers

  @default_config %{
    github_token: System.get_env("GITHUB_TOKEN"),
    # 既定 org は持たない（issue #28）。未設定のまま学生リポジトリ / レジストリを
    # 読むと他 org の smkwlab データを静かに対象にしてしまうため、未設定時は
    # registry_repo の owner から導出（apply_github_org_convention）し、それも無ければ
    # nil のままにして消費点（require_github_org!）で明示エラーにする。
    github_org: nil,
    # レジストリデータリポジトリ（owner/repo、contents API で読む）。未設定時は
    # "<github_org>/thesis-student-registry" 規約を導出する（DataSource.Registry）
    registry_repo: nil,
    cache_dir: "~/.cache/thesis-monitor",
    # 30分
    cache_ttl: 1800,
    # 学生名簿 CSV（任意）。ローカル管理方針のためリポジトリ・レジストリには置かない
    csv_path: nil,
    max_concurrency: 10,
    timeout: 10_000
  }

  # 環境変数レイヤ(THESIS_MONITOR_*)の spec。ファイルより後勝ち
  @env_spec %{
    github_token: :string,
    github_org: :string,
    registry_repo: :string,
    cache_dir: :string,
    cache_ttl: :integer,
    csv_path: :string,
    max_concurrency: :integer,
    timeout: :integer
  }

  def start_link(_opts) do
    Agent.start_link(fn -> @default_config end, name: __MODULE__)
  end

  def load(config_path \\ nil) do
    config =
      config_path
      |> resolve_layers()
      |> apply_github_org_convention()
      |> apply_csv_convention()

    case Process.whereis(__MODULE__) do
      nil ->
        Agent.start_link(fn -> config end, name: __MODULE__)

      pid ->
        Agent.update(__MODULE__, fn _ -> config end)
        {:ok, pid}
    end
  end

  @doc """
  CLI オプション由来の設定上書きを適用する（Config.load の後に呼ぶ）。

  `--no-cache` は cache_ttl を 0 にする。Cache は ttl <= 0 でキャッシュを
  読まず常に fetch する（fetch 結果の書き込みは行われるため、以後の
  通常実行もこのとき取得した最新値から始まる）。
  """
  def apply_cli_overrides(opts) do
    if opts[:no_cache] do
      Agent.update(__MODULE__, &Map.put(&1, :cache_ttl, 0))
    end

    :ok
  end

  # csv_path 未設定（nil / 空文字列）のとき、規約パス
  # ~/.config/<github_org>/students.csv が存在すればそれを使う（issue #16）。
  # 明示設定が常に優先。registry-manager も同じ規約パスを参照する。
  # 名簿はローカル管理方針のためリポジトリ・レジストリには置かない。
  # load の内部実装だが、home を注入したテストのために public にしている。
  # 空文字列は nil に正規化する（Map.put は "" → nil の正規化を兼ねる）
  @doc false
  def apply_csv_convention(config, home \\ System.user_home())

  def apply_csv_convention(%{csv_path: csv} = config, home) when csv in [nil, ""] do
    Map.put(config, :csv_path, Layers.find_conventional_csv(Map.get(config, :github_org), home))
  end

  def apply_csv_convention(config, _home), do: config

  # github_org 未設定（nil / 空文字列）のとき、registry_repo の owner を既定として
  # 使う（issue #28）。明示設定（config.yml / --org）が常に優先。registry_repo も
  # 未設定なら nil のままにし、消費点（require_github_org!）で明示エラーにさせる。
  # registry-manager#45 の owner→org 規約と揃えている。
  # load の内部実装だが、owner 導出を直接検証するテストのために public にしている
  # （同モジュールの apply_csv_convention と同じ慣習）。
  @doc false
  def apply_github_org_convention(config) do
    derived =
      Layers.derive_github_org(Map.get(config, :github_org), Map.get(config, :registry_repo))

    Map.put(config, :github_org, derived)
  end

  @github_org_error """
  github_org が設定されていません。config 無しで実行すると他 org の \
  レジストリ / 学生リポジトリを静かに対象にしてしまうため、既定 org は持ちません。

  `thesis-monitor init --org <your-org>` を実行して設定ファイルを生成するか、\
  ~/.config/thesis-monitor/config.yml に github_org（または owner を導出する \
  registry_repo）を設定してください。\
  """

  @doc """
  設定済みの github_org を返す。未設定（nil / 空）なら明示エラーで停止する（issue #28）。
  `owner/repo` 名を組み立てる呼び出し側が使い、他 org への静かな誤対象（`/repo`）を防ぐ。
  取得失敗を空リストに畳まない方針（DataSource）と同じく RuntimeError で明示する。
  """
  def require_github_org!(github_org) when is_binary(github_org) and github_org != "" do
    github_org
  end

  def require_github_org!(_github_org) do
    raise RuntimeError, @github_org_error
  end

  @doc """
  組織の名簿 CSV の規約パスを返す
  """
  def conventional_csv_path(github_org, home \\ System.user_home!())
      when is_binary(github_org) and is_binary(home) do
    Layers.conventional_csv_path(github_org, home)
  end

  @doc """
  既定の設定ファイルパス（issue #18 で ~/.config/thesis-monitor/config.yml に統一。
  旧 ~/.thesis-monitor.yml は読み込まない — 公開前に fallback を持たない決定）
  """
  def default_config_path(home \\ System.user_home!()) when is_binary(home) do
    Layers.default_config_path("thesis-monitor", home)
  end

  # Agent 未起動（escript の init 経路など Config.load 前の呼び出し）は
  # GenServer.call の exit になるため、rescue に加えて catch :exit が必要
  def get(key) when is_atom(key) do
    value = Agent.get(__MODULE__, &Map.get(&1, key))
    expand_path_value(key, value)
  rescue
    _ -> default_get(key)
  catch
    :exit, _ -> default_get(key)
  end

  def get_all do
    Agent.get(__MODULE__, & &1)
  rescue
    _ -> @default_config
  catch
    :exit, _ -> @default_config
  end

  defp default_get(key) do
    expand_path_value(key, Map.get(@default_config, key))
  end

  # パス系キーはチルダを展開
  defp expand_path_value(key, value) do
    case {key, value} do
      {:cache_dir, path} when is_binary(path) -> Layers.expand_home(path)
      {:csv_path, path} when is_binary(path) -> Layers.expand_home(path)
      _ -> value
    end
  end

  # defaults ⊕ ファイル ⊕ 環境変数(THESIS_MONITOR_*)を後勝ちでマージする。
  # 探索順(--config → ./config/thesis-monitor.yml → ~/.config/... → defaults)は
  # first_existing で解決する(明示パスが不存在なら次の候補へ、従来と同じ)
  defp resolve_layers(config_path) do
    file_path =
      Layers.first_existing([
        config_path,
        "./config/thesis-monitor.yml",
        default_config_path()
      ])

    Layers.merge([@default_config, file_layer(file_path), env_layer()])
  end

  defp file_layer(nil), do: %{}

  # 旧キー（data_dir / student_csv / registry_dir）の互換は持たない
  # （公開前に後方互換を全廃する決定、issue #20）。defaults に無いキーも
  # 従来通り atom 化して取り込む。パース失敗は defaults へのフォールバック
  defp file_layer(path) do
    case Layers.load_file(path) do
      {:ok, raw} -> Map.new(raw, fn {k, v} -> {String.to_atom(k), v} end)
      {:error, {:parse_error, _path}} -> %{}
    end
  end

  # 変換失敗（不正な integer 等）はその変数を無視して他レイヤの値を使う
  defp env_layer do
    case Layers.read_env("THESIS_MONITOR", @env_spec) do
      {:ok, env} -> env
      {:error, _message} -> %{}
    end
  end
end
