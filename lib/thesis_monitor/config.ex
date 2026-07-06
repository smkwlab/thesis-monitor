defmodule ThesisMonitor.Config do
  @moduledoc """
  設定管理モジュール
  """

  use Agent

  @default_config %{
    github_token: System.get_env("GITHUB_TOKEN"),
    github_org: "smkwlab",
    # レジストリデータリポジトリ（owner/repo、contents API で読む）。未設定時は
    # "<github_org>/thesis-student-registry" 規約を導出する（DataSource.Registry）
    registry_repo: nil,
    # legacy: ローカル checkout の data/ ディレクトリ（1 世代、registry_repo へ移行推奨）
    registry_dir: nil,
    cache_dir: "~/.cache/thesis-monitor",
    # 30分
    cache_ttl: 1800,
    # 学生名簿 CSV（任意）。ローカル管理方針のためリポジトリ・レジストリには置かない
    csv_path: nil,
    max_concurrency: 10,
    timeout: 10_000
  }

  def start_link(_opts) do
    Agent.start_link(fn -> @default_config end, name: __MODULE__)
  end

  def load(config_path \\ nil) do
    config =
      cond do
        config_path && File.exists?(config_path) ->
          load_from_file(config_path)

        File.exists?("./config/thesis-monitor.yml") ->
          load_from_file("./config/thesis-monitor.yml")

        File.exists?(Path.expand("~/.thesis-monitor.yml")) ->
          load_from_file(Path.expand("~/.thesis-monitor.yml"))

        true ->
          @default_config
      end

    case Process.whereis(__MODULE__) do
      nil ->
        Agent.start_link(fn -> config end, name: __MODULE__)

      pid ->
        Agent.update(__MODULE__, fn _ -> config end)
        {:ok, pid}
    end
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
      {:registry_dir, path} when is_binary(path) -> Path.expand(path)
      {:cache_dir, path} when is_binary(path) -> Path.expand(path)
      {:csv_path, path} when is_binary(path) -> Path.expand(path)
      _ -> value
    end
  end

  defp load_from_file(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, yaml} ->
        yaml
        |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
        |> Enum.into(@default_config)
        |> migrate_legacy_keys(path)

      _ ->
        @default_config
    end
  end

  # 旧キーの 1 世代後方互換:
  #   data_dir → registry_dir（issue #7）、student_csv → csv_path（issue #14）は
  #   同じ意味のまま改名なので値を新キーへ昇格する。
  #   registry_dir → registry_repo（issue #14）は値の意味が変わる（ローカルパス vs
  #   owner/repo）ため自動昇格できず、警告して手動移行を促すだけにする。
  # 移行後は旧キーを残さない（get_all や get(:data_dir) から古い値が見えないように）
  defp migrate_legacy_keys(config, path) do
    config
    |> migrate_renamed_key(:data_dir, :registry_dir, path)
    |> migrate_renamed_key(:student_csv, :csv_path, path)
    |> warn_deprecated_registry_dir(path)
  end

  defp migrate_renamed_key(config, old_key, new_key, path) do
    cond do
      not Map.has_key?(config, old_key) ->
        config

      is_binary(Map.get(config, new_key)) ->
        IO.puts(
          :stderr,
          "warning: config key \"#{old_key}\" is ignored because \"#{new_key}\" is set (#{path})"
        )

        Map.delete(config, old_key)

      is_binary(Map.get(config, old_key)) ->
        IO.puts(
          :stderr,
          "warning: config key \"#{old_key}\" is deprecated, rename it to \"#{new_key}\" (#{path})"
        )

        config
        |> Map.put(new_key, Map.get(config, old_key))
        |> Map.delete(old_key)

      true ->
        Map.delete(config, old_key)
    end
  end

  defp warn_deprecated_registry_dir(config, path) do
    case config do
      %{registry_repo: repo, registry_dir: dir}
      when is_binary(repo) and repo != "" and is_binary(dir) ->
        IO.puts(
          :stderr,
          "warning: config key \"registry_dir\" is ignored because \"registry_repo\" is set (#{path})"
        )

        Map.put(config, :registry_dir, nil)

      %{registry_dir: dir} when is_binary(dir) ->
        IO.puts(
          :stderr,
          "warning: config key \"registry_dir\" (local checkout) is deprecated, " <>
            "switch to \"registry_repo\" — run `thesis-monitor init --force` (#{path})"
        )

        config

      _ ->
        config
    end
  end
end
