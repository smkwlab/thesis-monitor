defmodule ThesisMonitor.DataSource.LocalTest do
  use ExUnit.Case, async: true
  alias ThesisMonitor.DataSource.Local

  describe "registry file resolution (issue #7)" do
    @entry ~s({"k21rs001-sotsuron": {"student_id": "k21rs001", "repository_type": "sotsuron"}})
    @legacy_entry ~s({"k22rs002-sotsuron": {"student_id": "k22rs002", "repository_type": "sotsuron"}})

    defp make_registry_dir(prefix) do
      test_dir =
        System.tmp_dir()
        |> Path.join("#{prefix}_#{System.unique_integer([:positive])}")

      File.mkdir_p!(test_dir)
      on_exit(fn -> File.rm_rf!(test_dir) end)
      test_dir
    end

    defp registry_dir_config(test_dir) do
      fn
        :registry_dir -> test_dir
        _ -> nil
      end
    end

    test "reads registry.json via the registry_dir config key" do
      test_dir = make_registry_dir("test_registry_new")
      File.write!(Path.join(test_dir, "registry.json"), @entry)

      {:ok, students} = Local.get_registry_students(registry_dir_config(test_dir))
      assert [%{id: "k21rs001"}] = students
    end

    test "falls back to repositories.json when registry.json is absent" do
      test_dir = make_registry_dir("test_registry_legacy")
      File.write!(Path.join(test_dir, "repositories.json"), @legacy_entry)

      {:ok, students} = Local.get_registry_students(registry_dir_config(test_dir))
      assert [%{id: "k22rs002"}] = students
    end

    test "prefers registry.json when both files exist" do
      test_dir = make_registry_dir("test_registry_both")
      File.write!(Path.join(test_dir, "registry.json"), @entry)
      File.write!(Path.join(test_dir, "repositories.json"), @legacy_entry)

      {:ok, students} = Local.get_registry_students(registry_dir_config(test_dir))
      assert [%{id: "k21rs001"}] = students
    end
  end

  describe "get_students/1" do
    test "parses student entries from protection file" do
      test_dir = System.tmp_dir() |> Path.join("test_protection_#{:rand.uniform(10000)}")
      File.mkdir_p!(test_dir)

      protection_dir = Path.join(test_dir, "protection-status")
      File.mkdir_p!(protection_dir)
      protection_file = Path.join(protection_dir, "completed-protection.txt")

      File.write!(protection_file, """
      k21rs001-sotsuron # Completed: 2025-06-23 Student: k21rs001
      k22jk059-sotsuron # Completed: 2025-06-24 Student: k22jk059
      k23gjk01-thesis # Completed: 2025-06-24 Student: k23gjk01
      Some invalid line
      """)

      mock_config = fn
        :registry_dir -> test_dir
        _ -> nil
      end

      try do
        {:ok, students} = Local.get_students(mock_config)

        assert length(students) == 3
        student_ids = Enum.map(students, & &1.id)
        assert "k21rs001" in student_ids
        assert "k22jk059" in student_ids
        assert "k23gjk01" in student_ids
        assert Enum.all?(students, &(&1.status == :protected))
      after
        File.rm_rf!(test_dir)
      end
    end

    test "handles missing protection file" do
      test_dir = System.tmp_dir() |> Path.join("test_missing_#{:rand.uniform(10000)}")

      mock_config = fn
        :registry_dir -> test_dir
        _ -> nil
      end

      {:ok, students} = Local.get_students(mock_config)
      assert students == []
    end

    test "handles fallback regex" do
      test_dir = System.tmp_dir() |> Path.join("test_fallback_#{:rand.uniform(10000)}")
      File.mkdir_p!(test_dir)

      protection_dir = Path.join(test_dir, "protection-status")
      File.mkdir_p!(protection_dir)
      protection_file = Path.join(protection_dir, "completed-protection.txt")

      File.write!(protection_file, """
      k21rs001
      k22jk002
      invalid_line
      """)

      mock_config = fn
        :registry_dir -> test_dir
        _ -> nil
      end

      try do
        {:ok, students} = Local.get_students(mock_config)
        assert length(students) == 2
      after
        File.rm_rf!(test_dir)
      end
    end

    test "raises when registry_dir is nil" do
      mock_config = fn
        :registry_dir -> nil
        _ -> nil
      end

      assert_raise RuntimeError, ~r/Registry directory not configured/, fn ->
        Local.get_students(mock_config)
      end
    end
  end

  describe "get_registry_students/1" do
    test "parses JSON registry file" do
      test_dir = System.tmp_dir() |> Path.join("test_registry_#{:rand.uniform(10000)}")
      File.mkdir_p!(test_dir)

      registry_file = Path.join(test_dir, "repositories.json")

      registry_data = %{
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "status" => "active"
        },
        "k22jk002-sotsuron" => %{
          "student_id" => "k22jk002",
          "repository_type" => "sotsuron",
          "status" => "inactive"
        }
      }

      File.write!(registry_file, Jason.encode!(registry_data))

      mock_config = fn
        :registry_dir -> test_dir
        _ -> nil
      end

      try do
        {:ok, students} = Local.get_registry_students(mock_config)

        assert length(students) == 2
        k21_student = Enum.find(students, &(&1.id == "k21rs001"))
        assert k21_student.repo_name == "k21rs001-sotsuron"
        assert k21_student.type == "sotsuron"
        assert k21_student.status == :active
      after
        File.rm_rf!(test_dir)
      end
    end

    test "handles missing registry file" do
      test_dir = System.tmp_dir() |> Path.join("test_missing_registry_#{:rand.uniform(10000)}")

      mock_config = fn
        :registry_dir -> test_dir
        _ -> nil
      end

      {:ok, students} = Local.get_registry_students(mock_config)
      assert students == []
    end

    test "handles invalid JSON" do
      test_dir = System.tmp_dir() |> Path.join("test_invalid_json_#{:rand.uniform(10000)}")
      File.mkdir_p!(test_dir)

      registry_file = Path.join(test_dir, "repositories.json")
      File.write!(registry_file, "invalid json")

      mock_config = fn
        :registry_dir -> test_dir
        _ -> nil
      end

      try do
        {:ok, students} = Local.get_registry_students(mock_config)
        assert students == []
      after
        File.rm_rf!(test_dir)
      end
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
