defmodule ThesisMonitor.DataSource.LocalTest do
  use ExUnit.Case, async: true
  alias ThesisMonitor.DataSource.Local
  alias ThesisMonitor.Student

  describe "parse_protection_content/1" do
    test "parses student entries and the fallback line format" do
      content = """
      Student: k21rs001 - Protected
      k22jk002 protected at 2026-01-01
      not a student line
      """

      students = Local.parse_protection_content(content)

      assert [
               %Student{id: "k21rs001", status: :protected},
               %Student{id: "k22jk002", status: :protected}
             ] = students

      assert hd(students).repo_name == "k21rs001-sotsuron"
    end
  end

  describe "parse_registry_data/1" do
    test "builds students from decoded registry data, skipping invalid entries" do
      data = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "status" => "active"
        },
        "broken-entry" => %{"no_student_id" => true}
      }

      assert [%Student{id: "k21rs001", repo_name: "k21rs001-sotsuron", repo_type: "sotsuron"}] =
               Local.parse_registry_data(data)
    end
  end

  describe "get_student_names/1" do
    test "parses CSV and converts student IDs" do
      test_dir = System.tmp_dir() |> Path.join("test_csv_#{:rand.uniform(10000)}")
      File.mkdir_p!(test_dir)

      csv_file = Path.join(test_dir, "students.csv")

      File.write!(csv_file, """
      学年,学科,学籍番号,氏名
      4,情報,21RS001,田中太郎
      4,情報,22JK002,佐藤花子
      4,情報,23GJK003,山田三郎
      """)

      mock_config = fn
        :csv_path -> csv_file
        _ -> nil
      end

      try do
        {:ok, names_map} = Local.get_student_names(mock_config)

        assert names_map["k21rs001"] == "田中太郎"
        assert names_map["k22jk002"] == "佐藤花子"
        assert names_map["k23gjk003"] == "山田三郎"
      after
        File.rm_rf!(test_dir)
      end
    end

    test "handles missing CSV config" do
      mock_config = fn
        :csv_path -> nil
        _ -> nil
      end

      {:ok, names_map} = Local.get_student_names(mock_config)
      assert names_map == %{}
    end

    test "handles malformed CSV" do
      test_dir = System.tmp_dir() |> Path.join("test_malformed_#{:rand.uniform(10000)}")
      File.mkdir_p!(test_dir)

      csv_file = Path.join(test_dir, "malformed.csv")

      File.write!(csv_file, """
      学年,学科,学籍番号,氏名
      ,,21RS001,田中太郎
      ,,INVALID,無効
      ,,22JK002,佐藤花子
      """)

      mock_config = fn
        :csv_path -> csv_file
        _ -> nil
      end

      try do
        {:ok, names_map} = Local.get_student_names(mock_config)

        assert names_map["k21rs001"] == "田中太郎"
        assert names_map["k22jk002"] == "佐藤花子"
        refute Map.has_key?(names_map, "invalid")
      after
        File.rm_rf!(test_dir)
      end
    end

    test "resolves student_id and name columns by header name regardless of column order (17-column roster, CRLF)" do
      test_dir = System.tmp_dir() |> Path.join("test_csv_header_#{:rand.uniform(10000)}")
      File.mkdir_p!(test_dir)

      csv_file = Path.join(test_dir, "students.csv")

      # 実運用の名簿は先頭に卒業年度・修了年度・大学院学籍番号などが加わり、
      # 学籍番号/学生氏名の列位置が変動する。列名から解決できることと、
      # CRLF 改行に対応することを検証する。
      File.write!(
        csv_file,
        "卒業年度,修了年度,大学院学籍番号,学籍番号,学生氏名,カナ氏名\r\n" <>
          "2025,,24GJK02,21RS001,田中太郎,タナカタロウ\r\n" <>
          "2025,,,22JK002,佐藤花子,サトウハナコ\r\n"
      )

      mock_config = fn
        :csv_path -> csv_file
        _ -> nil
      end

      try do
        {:ok, names_map} = Local.get_student_names(mock_config)

        assert names_map["k21rs001"] == "田中太郎"
        assert names_map["k22jk002"] == "佐藤花子"
      after
        File.rm_rf!(test_dir)
      end
    end

    test "ignores blank lines, including a leading blank line before the header" do
      test_dir = System.tmp_dir() |> Path.join("test_csv_blank_#{:rand.uniform(10000)}")
      File.mkdir_p!(test_dir)

      csv_file = Path.join(test_dir, "students.csv")

      # 先頭・中間・末尾に空行が混じっても、ヘッダ解決とパースが成功すること。
      File.write!(csv_file, "\n学籍番号,学生氏名\n21RS001,田中太郎\n\n22JK002,佐藤花子\n")

      mock_config = fn
        :csv_path -> csv_file
        _ -> nil
      end

      try do
        {:ok, names_map} = Local.get_student_names(mock_config)

        assert names_map["k21rs001"] == "田中太郎"
        assert names_map["k22jk002"] == "佐藤花子"
      after
        File.rm_rf!(test_dir)
      end
    end

    test "strips a UTF-8 BOM so the first header column still resolves" do
      test_dir = System.tmp_dir() |> Path.join("test_csv_bom_#{:rand.uniform(10000)}")
      File.mkdir_p!(test_dir)

      csv_file = Path.join(test_dir, "students.csv")

      # Excel などが書き出す UTF-8 BOM を先頭に付ける。BOM を残すと先頭列名
      # （ここでは学籍番号）が一致せず、氏名が解決できなくなる。
      File.write!(csv_file, <<0xEF, 0xBB, 0xBF>> <> "学籍番号,学生氏名\n21RS001,田中太郎\n")

      mock_config = fn
        :csv_path -> csv_file
        _ -> nil
      end

      try do
        {:ok, names_map} = Local.get_student_names(mock_config)

        assert names_map["k21rs001"] == "田中太郎"
      after
        File.rm_rf!(test_dir)
      end
    end
  end
end
