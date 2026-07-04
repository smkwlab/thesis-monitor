defmodule ThesisMonitor.Config do
  @moduledoc """
  設定管理モジュール
  """

  use Agent

  @default_config %{
    github_token: System.get_env("GITHUB_TOKEN"),
    github_org: "smkwlab",
    # Must be set in config file
    data_dir: nil,
    cache_dir: "~/.cache/thesis-monitor",
    # 30分
    cache_ttl: 1800,
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

  def get(key) when is_atom(key) do
    value = Agent.get(__MODULE__, &Map.get(&1, key))

    # data_dirの場合、チルダを展開
    case {key, value} do
      {:data_dir, path} when is_binary(path) -> Path.expand(path)
      {:cache_dir, path} when is_binary(path) -> Path.expand(path)
      _ -> value
    end
  rescue
    _ ->
      default_value = Map.get(@default_config, key)

      case {key, default_value} do
        {:cache_dir, path} when is_binary(path) -> Path.expand(path)
        _ -> default_value
      end
  end

  def get_all do
    Agent.get(__MODULE__, & &1)
  rescue
    _ -> @default_config
  end

  defp load_from_file(path) do
    case YamlElixir.read_from_file(path) do
      {:ok, yaml} ->
        yaml
        |> Enum.map(fn {k, v} -> {String.to_atom(k), v} end)
        |> Enum.into(@default_config)

      _ ->
        @default_config
    end
  end
end
