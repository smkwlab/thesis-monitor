defmodule ThesisMonitor.Output do
  @moduledoc """
  出力フォーマット管理モジュール
  """

  use Agent

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
    # Calculate column widths
    widths = calculate_column_widths(headers, rows)

    # Format header
    header = format_row(headers, widths)
    separator = format_separator(widths)

    # Format data rows
    formatted_rows = Enum.map(rows, &format_row(&1, widths))

    [header, separator | formatted_rows]
    |> Enum.join("\n")
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

  defp calculate_column_widths(headers, rows) do
    all_data = [headers | rows]

    headers
    |> Enum.with_index()
    |> Enum.map(fn {header, index} ->
      if header == "Name" do
        # Name列の場合は表示幅ベースで計算（最大16文字）
        name_width =
          all_data
          |> Enum.map(&Enum.at(&1, index, ""))
          |> Enum.map(&to_string/1)
          |> Enum.map(&calculate_string_display_width/1)
          |> Enum.max()
          # "Name"の最小幅
          |> max(4)
          # 最大幅16文字
          |> min(16)

        name_width
      else
        # その他の列は従来通り文字数ベース
        calculated_width =
          all_data
          |> Enum.map(&Enum.at(&1, index, ""))
          |> Enum.map(&to_string/1)
          |> Enum.map(&String.length/1)
          |> Enum.max()
          # Minimum width
          |> max(8)

        calculated_width
      end
    end)
  end

  defp format_row(row, widths) do
    row
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {cell, index} ->
      width = Enum.at(widths, index, 10)
      cell_str = to_string(cell)
      truncated = truncate_string(cell_str, width)
      pad_string_with_display_width(truncated, width)
    end)
  end

  # 表示幅を考慮した文字列パディング
  defp pad_string_with_display_width(string, target_width) do
    current_display_width = calculate_string_display_width(string)
    padding_needed = target_width - current_display_width

    if padding_needed > 0 do
      string <> String.duplicate(" ", padding_needed)
    else
      string
    end
  end

  defp format_separator(widths) do
    Enum.map_join(widths, " ", &String.duplicate("-", &1))
  end

  defp truncate_string(string, max_length) do
    display_width = calculate_string_display_width(string)

    if display_width <= max_length do
      string
    else
      truncate_by_display_width(string, max_length)
    end
  end

  # 文字列の表示幅を計算（日本語文字=2幅、ASCII=1幅）
  defp calculate_string_display_width(string) do
    string
    |> String.graphemes()
    |> Enum.reduce(0, fn char, acc ->
      char_width = if String.match?(char, ~r/[^\x00-\x7F]/), do: 2, else: 1
      acc + char_width
    end)
  end

  # 表示幅ベースで文字列を切り詰め
  defp truncate_by_display_width(string, max_width) when max_width <= 3 do
    String.slice(string, 0, max_width)
  end

  defp truncate_by_display_width(string, max_width) do
    chars = String.graphemes(string)

    {result_chars, _current_width} =
      Enum.reduce_while(chars, {[], 0}, fn char, {acc_chars, acc_width} ->
        char_width = if String.match?(char, ~r/[^\x00-\x7F]/), do: 2, else: 1
        new_width = acc_width + char_width

        # "..."の分（3文字幅）を考慮
        if new_width + 3 > max_width do
          {:halt, {acc_chars, acc_width}}
        else
          {:cont, {[char | acc_chars], new_width}}
        end
      end)

    result_chars |> Enum.reverse() |> Enum.join("") |> Kernel.<>("...")
  end

  defp color(name) do
    if IO.ANSI.enabled?() do
      @colors[name] || ""
    else
      ""
    end
  end
end
