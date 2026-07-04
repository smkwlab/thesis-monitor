defmodule ThesisMonitor.TokenManager do
  @moduledoc """
  GitHub トークン管理Agent
  設定ファイル、環境変数、GitHub CLIからトークンを取得し、キャッシュする
  """

  use Agent
  alias ThesisMonitor.{Config, Output}

  @doc """
  TokenManagerを開始し、起動時にトークンを取得
  """
  def start_link(_opts \\ []) do
    # 起動時にトークンを取得
    {token, source} = fetch_token()

    # ログ出力
    case source do
      :gh_cli -> Output.info("Using GitHub token from 'gh auth token'")
      _ -> :ok
    end

    initial_state = %{token: token, source: source}
    Agent.start_link(fn -> initial_state end, name: __MODULE__)
  end

  @doc """
  GitHubトークンを取得（起動時に既に取得済み）
  """
  def get_token do
    Agent.get(__MODULE__, &Map.get(&1, :token))
  rescue
    # Agentが開始されていない場合の処理
    _ ->
      {:ok, _pid} = start_link()
      Agent.get(__MODULE__, &Map.get(&1, :token))
  end

  @doc """
  トークンの取得元を返す（デバッグ用）
  """
  def get_source do
    Agent.get(__MODULE__, &Map.get(&1, :source))
  rescue
    _ -> nil
  end

  defp fetch_token do
    cond do
      token = Config.get(:github_token) ->
        {token, :config}

      token = System.get_env("GITHUB_TOKEN") ->
        {token, :env}

      token = get_token_from_gh_cli() ->
        {token, :gh_cli}

      true ->
        {"", :none}
    end
  end

  defp get_token_from_gh_cli do
    case System.cmd("gh", ["auth", "token"], stderr_to_stdout: true) do
      {token, 0} ->
        String.trim(token)

      {_error, _exit_code} ->
        nil
    end
  rescue
    # gh コマンドが存在しない場合
    _ -> nil
  end
end
