defmodule ThesisMonitor.DataSource.Registry do
  @moduledoc """
  レジストリ読み取りの入口。取得元を config から解決する:

  1. `registry_repo` 設定時 → GitHub contents API（cache_dir/cache_ttl でキャッシュ）
  2. `registry_dir` のみ設定時 → ローカル checkout 読み（1 世代 legacy）
  3. どちらも未設定 → 規約 `<github_org>/thesis-student-registry` を API 読み
     （ECOSYSTEM.md「Organization-Scoped Deployment」。空文字列は未設定扱い）

  レジストリは private リポジトリなので、API 経路の取得失敗（権限不足・不在）は
  空リストに畳まず RuntimeError で明示する（CLI.main が rescue して表示・halt する）。
  """

  alias ThesisMonitor.{Cache, Config}
  alias ThesisMonitor.DataSource.{GitHubAPI, Local}

  @registry_repo_basename "thesis-student-registry"
  @registry_file_path "data/registry.json"
  # 旧ファイル名（repositories.json → registry.json 改名の移行期間中のみ、issue #7）
  @legacy_registry_file_path "data/repositories.json"
  @protection_file_path "data/protection-status/completed-protection.txt"

  @doc false
  def resolve_source(config_fn \\ &Config.get/1) do
    repo = config_fn.(:registry_repo)
    dir = config_fn.(:registry_dir)

    cond do
      is_binary(repo) and repo != "" ->
        {:api, repo}

      is_binary(dir) ->
        # deprecation 警告は Config.load（migrate_legacy_keys）が 1 回だけ出す
        :local

      true ->
        {:api, "#{config_fn.(:github_org)}/#{@registry_repo_basename}"}
    end
  end

  @doc """
  レジストリ（registry.json）から学生情報を取得
  """
  def get_registry_students(
        config_fn \\ &Config.get/1,
        fetch_fn \\ &GitHubAPI.get_file_contents/2
      ) do
    case resolve_source(config_fn) do
      :local -> Local.get_registry_students(config_fn)
      {:api, repo} -> fetch_registry(repo, config_fn, fetch_fn)
    end
  end

  @doc """
  保護設定完了済み学生のリストを取得（protection-status ファイル。無ければ空）

  ファイル不在（404）は任意ファイルなので空リストだが、401/403 は
  レジストリ自体への権限欠如と同義なので registry.json と同様に raise する
  """
  def get_students(config_fn \\ &Config.get/1, fetch_fn \\ &GitHubAPI.get_file_contents/2) do
    case resolve_source(config_fn) do
      :local ->
        Local.get_students(config_fn)

      {:api, repo} ->
        case fetch_cached(repo, @protection_file_path, config_fn, fetch_fn) do
          {:ok, content} -> {:ok, Local.parse_protection_content(content)}
          {:error, :not_found} -> {:ok, []}
          {:error, reason} -> raise_api_error(repo, @protection_file_path, reason)
        end
    end
  end

  defp fetch_registry(repo, config_fn, fetch_fn) do
    case fetch_json_cached(repo, @registry_file_path, config_fn, fetch_fn) do
      {:ok, data} ->
        {:ok, Local.parse_registry_data(data)}

      {:error, :not_found} ->
        fetch_legacy_registry(repo, config_fn, fetch_fn)

      {:error, reason} ->
        raise_api_error(repo, @registry_file_path, reason)
    end
  end

  defp fetch_legacy_registry(repo, config_fn, fetch_fn) do
    case fetch_json_cached(repo, @legacy_registry_file_path, config_fn, fetch_fn) do
      {:ok, data} ->
        {:ok, Local.parse_registry_data(data)}

      {:error, :not_found} ->
        raise RuntimeError, """
        Registry file not found in #{repo} (#{@registry_file_path}).

        レジストリデータリポジトリが未初期化の場合は registry-manager の init
        （bootstrap）で作成してください: https://github.com/smkwlab/registry-manager
        別のリポジトリを使う場合は config の registry_repo を設定してください。
        """

      {:error, reason} ->
        raise_api_error(repo, @legacy_registry_file_path, reason)
    end
  end

  defp fetch_cached(repo, path, config_fn, fetch_fn) do
    Cache.get_or_fetch("#{repo}:#{path}", fn -> fetch_fn.(repo, path) end, config_fn)
  end

  # JSON ファイル用: fetch 時に検証してから（Cache 側で）保存し、不正 JSON を
  # 学生ゼロに畳まず明示エラーにする。キャッシュ済み内容の decode 失敗
  # （ファイル破損など）も同様に {:error, :invalid_json} → raise に載せる
  defp fetch_json_cached(repo, path, config_fn, fetch_fn) do
    validated_fetch = fn ->
      with {:ok, content} <- fetch_fn.(repo, path) do
        validate_json(content)
      end
    end

    case Cache.get_or_fetch("#{repo}:#{path}", validated_fetch, config_fn) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, :invalid_json}
        end

      error ->
        error
    end
  end

  defp validate_json(content) do
    case Jason.decode(content) do
      {:ok, _} -> {:ok, content}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  @spec raise_api_error(String.t(), String.t(), term()) :: no_return()
  defp raise_api_error(repo, path, :unauthorized) do
    raise RuntimeError, """
    GitHub token cannot read #{repo}/#{path} (401/403).

    レジストリは private リポジトリです。トークンに #{repo} の Contents: Read
    権限があるか確認してください（gh auth status / GITHUB_TOKEN / config の github_token）。
    """
  end

  defp raise_api_error(repo, path, :invalid_json) do
    raise RuntimeError, """
    Registry file #{repo}/#{path} contains invalid JSON.

    上流ファイルの破損、またはローカルキャッシュ（config の cache_dir 配下）の
    破損が考えられます。キャッシュを削除して再実行してください。
    """
  end

  defp raise_api_error(repo, path, reason) do
    raise RuntimeError,
          "Failed to fetch #{repo}/#{path} from GitHub API: #{inspect(reason)}"
  end
end
