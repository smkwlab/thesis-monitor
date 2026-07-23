defmodule ThesisMonitor.Output do
  @moduledoc """
  出力フォーマット管理モジュール
  """

  use Agent

  alias ToolKit.Output.Table

  @colors %{
    red: "\e[31m",
    green: "\e[32m",
    yellow: "\e[33m",
    blue: "\e[34m",
    reset: "\e[0m"
  }

  def start_link(opts \\ []) do
    verbose = Keyword.get(opts, :verbose, false)
    Agent.start_link(fn -> %{verbose: verbose} end, name: __MODULE__)
  end

  def set_verbose(verbose) when is_boolean(verbose) do
    Agent.update(__MODULE__, &Map.put(&1, :verbose, verbose))
  end

  def verbose? do
    Agent.get(__MODULE__, &Map.get(&1, :verbose, false))
  rescue
    _ -> false
  end

  def puts(message) do
    IO.puts(message)
  end

  def info(message) do
    if verbose?() do
      timestamp =
        DateTime.utc_now()
        |> DateTime.truncate(:second)
        |> DateTime.to_string()
        |> String.slice(0, 19)

      IO.puts("#{color(:blue)}[#{timestamp}]#{color(:reset)} #{message}")
    end
  end

  def success(message) do
    IO.puts("#{color(:green)}[SUCCESS]#{color(:reset)} #{message}")
  end

  def warn(message) do
    IO.puts("#{color(:yellow)}[WARNING]#{color(:reset)} #{message}")
  end

  def error(message) do
    IO.puts(:stderr, "#{color(:red)}[ERROR]#{color(:reset)} #{message}")
  end

  def print_table(headers, rows, title \\ nil, opts \\ []) do
    if title do
      IO.puts("\n#{title}")
      IO.puts(String.duplicate("=", String.length(title)))
    end

    if Enum.empty?(rows) do
      IO.puts("\nNo data available.")
    else
      IO.puts("")
      format = Keyword.get(opts, :format, :compact)
      format_table_output(headers, rows, format)
    end
  end

  defp format_table_output(headers, rows, :compact) do
    {min_widths, max_widths} = width_constraints(headers)

    headers
    |> Table.render(rows, gap: " ", min_widths: min_widths, max_widths: max_widths)
    |> IO.puts()
  end

  defp format_table_output(headers, rows, :long) do
    # Tab-separated format for long output
    header = Enum.join(headers, "\t")
    separator = Enum.map_join(headers, "\t", fn _ -> String.duplicate("-", 10) end)
    formatted_rows = Enum.map(rows, &Enum.join(&1, "\t"))

    [header, separator | formatted_rows]
    |> Enum.join("\n")
    |> IO.puts()
  end

  # 列幅ポリシー: Name 列は表示幅ベースで min 4 / max 16、その他の列は min 8
  defp width_constraints(headers) do
    headers
    |> Enum.with_index()
    |> Enum.reduce({%{}, %{}}, fn {header, index}, {mins, maxs} ->
      if header == "Name" do
        {Map.put(mins, index, 4), Map.put(maxs, index, 16)}
      else
        {Map.put(mins, index, 8), maxs}
      end
    end)
  end

  defp color(name) do
    if IO.ANSI.enabled?() do
      @colors[name] || ""
    else
      ""
    end
  end
end
