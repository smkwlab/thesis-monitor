defmodule ThesisMonitor.DataSource.Local do
  @moduledoc """
  ローカルの名簿 CSV 読み込みと、レジストリ本文のパース

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
  # デコード済みレジストリデータを学生リストにする（Registry の API 経路から使う）
  def parse_registry_data(data) do
    data
    |> Enum.map(&parse_registry_entry/1)
    |> Enum.reject(&is_nil/1)
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

  # 名簿 CSV の論理カラムと、ヘッダ行での列名候補の対応。
  # 実運用 CSV は先頭に「卒業年度」「修了年度」等の列が加わり列位置が変動するため、
  # 列インデックスをハードコードせず、ヘッダ名から解決して列順の変化に強くする
  # （registry-manager Issue #31 と同じ方針）。

  # 学籍番号は「学籍番号」（学部）と「大学院学籍番号」の両方を対象にする。院生は
  # 大学院学籍番号でレジストリ登録されることがあり、内部進学者は両方を持つため、
  # 行内に存在する各学籍番号を同一氏名に対応づける（Issue #26）。
  @student_id_columns ["学籍番号", "大学院学籍番号"]

  # 氏名は実運用の「学生氏名」に加え、旧フォーマット互換で「氏名」も候補に含める。
  @student_name_columns ["学生氏名", "氏名"]

  # 名簿 CSV は各フィールドにカンマ・ダブルクォートを含まない単純形式を前提とし、
  # 単純なカンマ区切りで分割する（RFC 4180 のクォート/エスケープは非対応）。将来
  # クォート付き・カンマ入りフィールドが必要になった場合は、移植元の
  # registry-manager と足並みを揃えて NimbleCSV 等の RFC 4180 パーサを導入する。
  defp parse_csv_content(content) do
    case content |> strip_bom() |> split_csv_lines() |> reject_blank_lines() do
      [] ->
        %{}

      [header | rows] ->
        columns = resolve_csv_columns(header)
        Enum.reduce(rows, %{}, &process_csv_line(&1, columns, &2))
    end
  end

  # 末尾改行由来の空要素や空行を除く。先頭が空行だとヘッダ解決に失敗するため、
  # ヘッダ/データ行のパターンマッチより前にまとめて除去する。
  defp reject_blank_lines(lines), do: Enum.reject(lines, &(String.trim(&1) == ""))

  # Excel などが書き出す UTF-8 BOM を除去する。残すと先頭列のヘッダ名が
  # 一致せず、列解決が失敗する。
  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content

  # 実運用 CSV は CRLF 改行を含む場合があるため \r?\n で分割する（registry-manager Issue #31）。
  defp split_csv_lines(content), do: String.split(content, ~r/\r?\n/)

  # ヘッダ行から、学籍番号列（複数あり得る）と氏名列の位置を解決する。
  defp resolve_csv_columns(header_line) do
    headers =
      header_line
      |> String.split(",")
      |> Enum.map(&String.trim/1)

    %{
      # 学籍番号列は「学籍番号」「大学院学籍番号」の両方に対応するため複数 index を持つ。
      student_id_indexes: resolve_all_indexes(headers, @student_id_columns),
      # 氏名列は候補のうち最初に見つかった 1 列（無ければ nil）。
      student_name_index: resolve_first_index(headers, @student_name_columns)
    }
  end

  # 該当する列名すべての index を返す（見つからない候補は除く）。
  defp resolve_all_indexes(headers, names) do
    names
    |> Enum.map(fn name -> Enum.find_index(headers, &(&1 == name)) end)
    |> Enum.reject(&is_nil/1)
  end

  # 候補の列名のうち最初に見つかったものの index（無ければ nil）。
  defp resolve_first_index(headers, names) do
    Enum.find_value(names, fn name -> Enum.find_index(headers, &(&1 == name)) end)
  end

  defp process_csv_line(line, columns, acc) do
    parts = String.split(line, ",")
    student_name = field_at(parts, columns.student_name_index)

    # 行内に存在する各学籍番号（学部・大学院）を同一氏名に対応づける。
    columns.student_id_indexes
    |> Enum.map(&field_at(parts, &1))
    |> Enum.reduce(acc, &process_student_entry(&1, student_name, &2))
  end

  # 1 行分の指定 index の値を取り出す（trim 済み、index が nil なら nil）。
  defp field_at(_parts, nil), do: nil
  defp field_at(parts, index), do: parts |> Enum.at(index) |> trim_csv_value()

  defp trim_csv_value(nil), do: nil
  defp trim_csv_value(value), do: String.trim(value)

  defp process_student_entry(student_id_csv, student_name, acc)
       when is_binary(student_id_csv) and is_binary(student_name) and
              student_id_csv != "" and student_name != "" do
    case convert_csv_id_to_system_id(student_id_csv) do
      nil -> acc
      system_id -> Map.put(acc, system_id, student_name)
    end
  end

  defp process_student_entry(_student_id_csv, _student_name, acc), do: acc

  # CSVの学籍番号形式（例：80JK059）をシステム形式（例：k80jk059）に変換
  defp convert_csv_id_to_system_id(csv_id) do
    case Regex.run(~r/^(\d{2})([A-Z]{2,3})(\d+)$/, csv_id) do
      [_, year, type, number] ->
        "k#{year}#{String.downcase(type)}#{number}"

      _ ->
        nil
    end
  end
end
