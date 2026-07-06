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

      assert [%Student{id: "k21rs001", status: :protected}, %Student{id: "k22jk002"}] = students
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
      header
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
  end
end
