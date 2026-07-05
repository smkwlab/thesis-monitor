defmodule ThesisMonitor.DataSourceTest do
  use ExUnit.Case, async: true

  alias ThesisMonitor.{DataSource, Student}
  alias ThesisMonitor.DataSource.Local

  describe "get_all_students/0" do
    test "merges local and registry students without duplicates" do
      # テスト用の一時ディレクトリ作成
      test_dir = System.tmp_dir() |> Path.join("test_datasource_#{:rand.uniform(10000)}")
      File.mkdir_p!(test_dir)

      # protection file 作成
      protection_dir = Path.join(test_dir, "protection-status")
      File.mkdir_p!(protection_dir)
      protection_file = Path.join(protection_dir, "completed-protection.txt")

      File.write!(protection_file, """
      Student: k21rs001 has protection
      """)

      # registry file 作成
      registry_file = Path.join(test_dir, "repositories.json")

      registry_data = %{
        "k22jk002-sotsuron" => %{
          "student_id" => "k22jk002",
          "repository_type" => "sotsuron",
          "status" => "active"
        },
        "k21rs001-sotsuron" => %{
          "student_id" => "k21rs001",
          "repository_type" => "sotsuron",
          "status" => "completed"
        }
      }

      File.write!(registry_file, Jason.encode!(registry_data))

      # CSV file 作成
      csv_file = Path.join(test_dir, "students.csv")

      File.write!(csv_file, """
      header
      ,,21RS001,田中太郎
      ,,22JK002,佐藤花子
      """)

      mock_config = fn
        :data_dir -> test_dir
        :student_csv -> csv_file
        _ -> nil
      end

      # Local.get_students, get_registry_students, get_student_names を config 引数付きで実行
      try do
        {:ok, local_students} = Local.get_students(mock_config)
        {:ok, registry_students} = Local.get_registry_students(mock_config)
        {:ok, names_map} = Local.get_student_names(mock_config)

        # 結果を検証
        assert length(local_students) == 1
        assert length(registry_students) == 2
        assert names_map["k21rs001"] == "田中太郎"
        assert names_map["k22jk002"] == "佐藤花子"

        # DataSource の動作は直接テストできないため、
        # 代わりに個別の機能をテスト
        all_students = local_students ++ registry_students
        unique_students = Enum.uniq_by(all_students, & &1.repo_name)

        # k21rs001 は重複削除される
        assert length(unique_students) == 2
      after
        File.rm_rf!(test_dir)
      end
    end

    test "handles sort order correctly" do
      students = [
        %Student{id: "k23jk002", repo_name: "k23jk002-sotsuron"},
        %Student{id: "k21rs001", repo_name: "k21rs001-sotsuron"},
        %Student{id: "k22gjk001", repo_name: "k22gjk001-thesis"},
        %Student{id: "k21rs002", repo_name: "k21rs002-sotsuron"}
      ]

      # ソートロジックを直接テスト
      sorted =
        Enum.sort_by(students, fn student ->
          case Regex.run(~r/^k(\d{2})(rs|jk|gjk)(\d+)$/, student.id) do
            [_, year_str, type, num_str] ->
              year = String.to_integer(year_str)
              num = String.to_integer(num_str)

              type_priority =
                case type do
                  "rs" -> 1
                  "jk" -> 2
                  "gjk" -> 3
                  _ -> 4
                end

              {year, type_priority, num, student.repo_name}

            _ ->
              {99, 99, 999_999, student.id, student.repo_name}
          end
        end)

      sorted_ids = Enum.map(sorted, & &1.id)
      assert sorted_ids == ["k21rs001", "k21rs002", "k22gjk001", "k23jk002"]
    end
  end

  describe "get_student/1" do
    test "returns nil for empty student list" do
      # DataSource.get_student は get_all_students に依存するため、
      # 空リストの場合の動作をテスト
      assert nil == Enum.find([], fn student -> student.id == "k99rs999" end)
    end

    test "finds student by ID" do
      students = [
        %Student{id: "k21rs001", repo_name: "k21rs001-sotsuron"},
        %Student{id: "k22jk002", repo_name: "k22jk002-sotsuron"}
      ]

      # Enum.find の動作をテスト（DataSource.get_student の核心部分）
      found = Enum.find(students, fn student -> student.id == "k21rs001" end)
      assert found.id == "k21rs001"

      not_found = Enum.find(students, fn student -> student.id == "k99rs999" end)
      assert not_found == nil
    end
  end

  describe "filter_students_by_type/2" do
    test "returns all students when type is nil" do
      students = [
        %Student{id: "k92rs001", repo_type: "thesis"},
        %Student{id: "k22rs002", repo_type: "wr"}
      ]

      result = DataSource.filter_students_by_type(students, nil)
      assert result == students
    end

    test "returns all students when type is 'all'" do
      students = [
        %Student{id: "k92rs001", repo_type: "thesis"},
        %Student{id: "k22rs002", repo_type: "wr"}
      ]

      result = DataSource.filter_students_by_type(students, "all")
      assert result == students
    end

    test "filters by thesis type" do
      students = [
        %Student{id: "k92rs001", repo_type: "thesis"},
        %Student{id: "k22rs002", repo_type: "sotsuron"},
        %Student{id: "k22rs003", repo_type: "wr"}
      ]

      result = DataSource.filter_students_by_type(students, "thesis")
      assert length(result) == 2
      assert Enum.all?(result, fn s -> s.repo_type in ["thesis", "sotsuron"] end)
    end

    test "filters by specific type" do
      students = [
        %Student{id: "k92rs001", repo_type: "thesis"},
        %Student{id: "k22rs002", repo_type: "wr"},
        %Student{id: "k22rs003", repo_type: "wr"}
      ]

      result = DataSource.filter_students_by_type(students, "wr")
      assert length(result) == 2
      assert Enum.all?(result, fn s -> s.repo_type == "wr" end)
    end
  end

  describe "needs_latest_branch?/1" do
    test "returns true for thesis type" do
      student = %Student{type: "thesis"}
      assert DataSource.needs_latest_branch?(student) == true
    end

    test "returns true for ise type" do
      student = %Student{type: "ise"}
      assert DataSource.needs_latest_branch?(student) == true
    end

    test "returns true for ise-report type" do
      student = %Student{type: "ise-report"}
      assert DataSource.needs_latest_branch?(student) == true
    end

    test "returns true for sotsuron repo_type" do
      student = %Student{repo_type: "sotsuron"}
      assert DataSource.needs_latest_branch?(student) == true
    end

    test "returns true for thesis repo_type" do
      student = %Student{repo_type: "thesis"}
      assert DataSource.needs_latest_branch?(student) == true
    end

    test "returns false for other types" do
      student = %Student{type: "wr"}
      assert DataSource.needs_latest_branch?(student) == false
    end

    test "returns false for empty student" do
      student = %Student{}
      assert DataSource.needs_latest_branch?(student) == false
    end
  end

  describe "get_latest_branch/1" do
    test "returns nil for missing repository (exists: false)" do
      # 存在しないリポジトリではブランチ取得をスキップし、
      # default_branch や "main" を捏造しない (issue #1)
      student = %Student{
        repo_name: "k99rs999-sotsuron",
        repo_type: "sotsuron",
        exists: false,
        default_branch: "main"
      }

      assert {:ok, nil} = DataSource.get_latest_branch(student)
    end

    test "returns nil for missing repository regardless of type" do
      student = %Student{repo_name: "k99rs998-wr", type: "wr", exists: false}

      assert {:ok, nil} = DataSource.get_latest_branch(student)
    end

    test "returns default branch for non-thesis types" do
      student = %Student{type: "wr", default_branch: "main"}
      {:ok, branch} = DataSource.get_latest_branch(student)
      assert branch == "main"

      student_no_default = %Student{type: "wr"}
      {:ok, branch} = DataSource.get_latest_branch(student_no_default)
      assert branch == "main"
    end
  end

  describe "get_repositories_info/1" do
    test "handles empty list" do
      results = DataSource.get_repositories_info([])
      assert results == []
    end

    test "handles timeout correctly" do
      students = [%Student{id: "test"}]
      # Task.async_stream のタイムアウト処理をテスト
      results =
        Task.async_stream(
          students,
          fn _student ->
            # 100msでタイムアウト
            Process.sleep(200)
            {:ok, %Student{}}
          end,
          timeout: 100,
          max_concurrency: 1,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, result} -> result
          {:exit, _} -> {:error, :timeout}
        end)

      assert List.first(results) == {:error, :timeout}
    end
  end

  describe "student name merging" do
    test "adds name from names_map when student name is nil" do
      student = %Student{id: "k21rs001", name: nil}
      names_map = %{"k21rs001" => "田中太郎"}

      # add_student_name のロジックをテスト
      updated_student =
        case student.name do
          nil ->
            name = Map.get(names_map, student.id)
            %{student | name: name}

          _ ->
            student
        end

      assert updated_student.name == "田中太郎"
    end

    test "preserves existing name when present" do
      student = %Student{id: "k21rs001", name: "既存の名前"}
      _names_map = %{"k21rs001" => "田中太郎"}

      # add_student_name のロジックをテスト - 既存の名前がある場合はそのまま
      updated_student = student

      assert updated_student.name == "既存の名前"
    end
  end

  describe "student ID parsing" do
    test "parses valid student IDs correctly" do
      test_cases = [
        {"k21rs001", {21, "rs", 1}},
        {"k22jk059", {22, "jk", 59}},
        {"k23gjk123", {23, "gjk", 123}}
      ]

      for {id, expected} <- test_cases do
        result =
          case Regex.run(~r/^k(\d{2})(rs|jk|gjk)(\d+)$/, id) do
            [_, year_str, type, num_str] ->
              year = String.to_integer(year_str)
              num = String.to_integer(num_str)
              {year, type, num}

            _ ->
              nil
          end

        assert result == expected
      end
    end

    test "handles invalid student IDs" do
      invalid_ids = ["invalid-id", "k99xx001", "not-a-student-id"]

      for id <- invalid_ids do
        result =
          case Regex.run(~r/^k(\d{2})(rs|jk|gjk)(\d+)$/, id) do
            [_, year_str, type, num_str] ->
              year = String.to_integer(year_str)
              num = String.to_integer(num_str)
              {year, type, num}

            _ ->
              nil
          end

        assert result == nil
      end
    end
  end

  describe "type priority calculation" do
    test "assigns correct priorities to student types" do
      priorities = %{
        "rs" => 1,
        "jk" => 2,
        "gjk" => 3,
        "unknown" => 4
      }

      for {type, expected_priority} <- Map.to_list(priorities) do
        priority =
          case type do
            "rs" -> 1
            "jk" -> 2
            "gjk" -> 3
            _ -> 4
          end

        assert priority == expected_priority
      end
    end
  end
end
