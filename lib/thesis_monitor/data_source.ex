defmodule ThesisMonitor.DataSource do
  @moduledoc """
  データソース管理モジュール
  ローカルファイルとGitHub APIからのデータ取得を統一的に扱う
  """

  alias ThesisMonitor.{
    DataSource.GitHubAPI,
    DataSource.Local,
    DataSource.Registry,
    Student
  }

  @doc """
  全学生のリストを取得
  """
  def get_all_students do
    with {:ok, local_students} <- Registry.get_students(),
         {:ok, registry_students} <- Registry.get_registry_students(),
         {:ok, names_map} <- Local.get_student_names() do
      students =
        (local_students ++ registry_students)
        |> Enum.uniq_by(& &1.repo_name)
        |> Enum.map(&add_student_name(&1, names_map))
        |> Enum.sort_by(&student_sort_key/1)

      {:ok, students}
    else
      _error ->
        registry_only_students()
    end
  end

  # フォールバック: レジストリのみからデータを取得
  # （Registry は {:ok, _} を返すか raise するかのどちらか。ここに来るのは
  #   CSV 名簿の読み取りが {:error, _} を返した場合のみ）
  defp registry_only_students do
    {:ok, students} = Registry.get_registry_students()
    {:ok, add_names_if_available(students)}
  end

  # CSVから名前を取得できない場合でも、学生データは返す
  defp add_names_if_available(students) do
    case Local.get_student_names() do
      {:ok, names_map} -> Enum.map(students, &add_student_name(&1, names_map))
      _error -> students
    end
  end

  defp add_student_name(%Student{name: nil} = student, names_map) do
    name = Map.get(names_map, student.id)
    %{student | name: name}
  end

  defp add_student_name(student, _names_map), do: student

  @doc """
  指定された学籍番号の学生を取得
  """
  def get_student(student_id) do
    case get_all_students() do
      {:ok, students} ->
        Enum.find(students, fn student -> student.id == student_id end)
    end
  end

  @doc """
  学生のリポジトリ情報を取得
  """
  def get_repository_info(%Student{} = student) do
    GitHubAPI.get_repository_info(student)
  end

  @doc """
  複数学生のリポジトリ情報を並列取得
  """
  def get_repositories_info(students) when is_list(students) do
    students
    |> Task.async_stream(&get_repository_info/1,
      ordered: true,
      timeout: 10_000,
      max_concurrency: 10
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, _} -> {:error, :timeout}
    end)
  end

  @doc """
  ブランチ保護状態を確認
  """
  def check_branch_protection(%Student{} = student) do
    GitHubAPI.check_branch_protection(student)
  end

  @doc """
  リポジトリタイプで学生リストをフィルタリング
  """
  def filter_students_by_type(students, nil), do: students
  def filter_students_by_type(students, "all"), do: students

  # thesis フィルタ = 論文まとめ（sotsuron ∪ master）。thesis は repository_type の
  # 語彙ではなくフィルタ名（smkwlab/thesis-management-tools#471 の語彙設計）
  def filter_students_by_type(students, "thesis") do
    Enum.filter(students, fn student ->
      student.repo_type in ["sotsuron", "master"]
    end)
  end

  def filter_students_by_type(students, type) do
    Enum.filter(students, fn student ->
      student.repo_type == type
    end)
  end

  @doc """
  最近のアクティビティを取得
  """
  def get_recent_activity(%Student{} = student, days \\ 7) do
    GitHubAPI.get_recent_commits(student, days)
  end

  @doc """
  PR/Issue統計を取得
  """
  def get_pr_stats(%Student{} = student) do
    GitHubAPI.get_pr_issue_stats(student)
  end

  @doc """
  最新ブランチを取得（論文・ISEレポート用）

  リポジトリが存在しない場合（exists: false）はブランチを取得せず nil を返す
  """
  def get_latest_branch(%Student{exists: false}), do: {:ok, nil}

  def get_latest_branch(%Student{} = student) do
    if needs_latest_branch?(student) do
      GitHubAPI.get_latest_branch(student)
    else
      {:ok, student.default_branch || "main"}
    end
  end

  @doc """
  最新ブランチが必要なタイプかチェック
  """
  def needs_latest_branch?(%Student{type: type}) when type in ["thesis", "ise", "ise-report"],
    do: true

  # latex-template 派生（研究会原稿等）も draft レビュー運用のため追跡対象
  def needs_latest_branch?(%Student{repo_type: type})
      when type in ["sotsuron", "master", "latex"],
      do: true

  def needs_latest_branch?(_), do: false

  # 学生のソートキーを生成: {年度, 学科優先度, 番号, リポジトリ名}
  # 学籍番号の形式: k{年度2桁}{rs|jk|gjk}{番号}
  defp student_sort_key(student) do
    case parse_student_id(student.id) do
      {year, type, num} ->
        type_priority = get_type_priority(type)
        {year, type_priority, num, student.repo_name}

      nil ->
        # パースに失敗した場合は末尾に配置
        {99, 99, 999_999, student.id, student.repo_name}
    end
  end

  # 学科タイプの優先度を定義
  # 学部生
  defp get_type_priority("rs"), do: 1
  # 情報科学科
  defp get_type_priority("jk"), do: 2
  # 大学院
  defp get_type_priority("gjk"), do: 3
  # その他
  defp get_type_priority(_), do: 4

  # 学籍番号をパースして年度、学科、番号を抽出
  defp parse_student_id(id) do
    case Regex.run(~r/^k(\d{2})(rs|jk|gjk)(\d+)$/, id) do
      [_, year_str, type, num_str] ->
        year = String.to_integer(year_str)
        num = String.to_integer(num_str)
        {year, type, num}

      _ ->
        nil
    end
  end
end
