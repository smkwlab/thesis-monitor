defmodule ThesisMonitor.DataSource.Local do
  @moduledoc """
  ローカルの名簿 CSV 読み込みと、レジストリ/protection-status 本文のパース

  レジストリ本体の取得は DataSource.Registry（contents API）が担当する。
  名簿 CSV は個人情報を含むためローカル管理（リポジトリ・レジストリに置かない）。
  """

  alias ThesisMonitor.{Config, Student}

  defp get_student_csv_path(config_fn) do
    case config_fn.(:csv_path) do
      nil ->
        nil

      path when is_binary(path) ->
        Path.expand(path)
    end
  end

  @doc false
  # protection-status ファイルの本文をパースする（Registry の API 経路から使う）
  def parse_protection_content(content) do
    content
    |> String.split("\n")
    |> Enum.map(&parse_student_line/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  # デコード済みレジストリデータを学生リストにする（Registry の API 経路から使う）
  def parse_registry_data(data) do
    data
    |> Enum.map(&parse_registry_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_student_line(line) do
    case Regex.run(~r/Student: (k\d{2}(rs|jk|gjk)\d+)/, line) do
      [_, student_id | _] ->
        %Student{
          id: student_id,
          repo_name: determine_repo_name(student_id),
          status: :protected
        }

      _ ->
        # フォールバック: 行頭の学生IDを抽出
        case Regex.run(~r/^(k\d{2}(rs|jk|gjk)\d+)/, line) do
          [_, student_id | _] ->
            %Student{
              id: student_id,
              repo_name: determine_repo_name(student_id),
              status: :protected
            }

          _ ->
            nil
        end
    end
  end

  defp parse_registry_entry({repo_name, %{"student_id" => student_id} = data}) do
    %Student{
      id: student_id,
      repo_name: repo_name,
      repo_type: Map.get(data, "repository_type", "sotsuron"),
      type: Map.get(data, "repository_type", "sotsuron"),
      status: String.to_atom(Map.get(data, "status", "active")),
      updated_at: Map.get(data, "updated_at")
    }
  end

  defp parse_registry_entry(_), do: nil

  @doc """
  CSVファイルから学生名の対応表を取得
  """
  def get_student_names(config_fn \\ &Config.get/1) do
    csv_path = get_student_csv_path(config_fn)

    if csv_path && File.exists?(csv_path) do
      case File.read(csv_path) do
        {:ok, content} ->
          names_map = parse_csv_content(content)
          {:ok, names_map}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, %{}}
    end
  end

  defp parse_csv_content(content) do
    content
    |> String.split("\n")
    # ヘッダー行をスキップ
    |> Enum.drop(1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, &process_csv_line/2)
  end

  defp process_csv_line(line, acc) do
    case String.split(line, ",") do
      parts when length(parts) >= 4 ->
        # 3列目（0-indexed）
        student_id_csv = String.trim(Enum.at(parts, 2))
        # 4列目
        student_name = String.trim(Enum.at(parts, 3))

        process_student_entry(student_id_csv, student_name, acc)

      _ ->
        acc
    end
  end

  defp process_student_entry(student_id_csv, student_name, acc) do
    if student_id_csv != "" && student_name != "" do
      case convert_csv_id_to_system_id(student_id_csv) do
        nil -> acc
        system_id -> Map.put(acc, system_id, student_name)
      end
    else
      acc
    end
  end

  # CSVの学籍番号形式（例：80JK059）をシステム形式（例：k80jk059）に変換
  defp convert_csv_id_to_system_id(csv_id) do
    case Regex.run(~r/^(\d{2})([A-Z]{2,3})(\d+)$/, csv_id) do
      [_, year, type, number] ->
        "k#{year}#{String.downcase(type)}#{number}"

      _ ->
        nil
    end
  end

  defp determine_repo_name(student_id) do
    cond do
      Regex.match?(~r/^k\d{2}(rs|jk)\d+$/, student_id) ->
        "#{student_id}-sotsuron"

      Regex.match?(~r/^k\d{2}gjk\d+$/, student_id) ->
        "#{student_id}-master"

      true ->
        nil
    end
  end
end
