defmodule ThesisMonitor.Student do
  @moduledoc """
  学生情報を表す構造体
  """

  defstruct [
    # 学生ID (例: k21rs001)
    :id,
    # 学生氏名
    :name,
    # リポジトリ名 (例: k21rs001-sotsuron)
    :repo_name,
    # リポジトリタイプ (sotsuron, master, wr, ise, latex, other)
    :repo_type,
    # 文書種別 (wr, thesis-report, ise, thesis)
    :type,
    # ステータス (active, inactive, completed)
    :status,
    # ブランチ保護状態 (protected, unprotected)
    :protection_status,
    # リポジトリ存在フラグ
    :exists,
    # 最終プッシュ日時
    :last_push,
    # リポジトリ可視性 (public, private)
    :visibility,
    # デフォルトブランチ名
    :default_branch,
    # 最新ブランチ名（PR添削用）
    :latest_branch,
    # 最終更新日時
    :updated_at,
    # 教員の返信待ち PR 件数（Issue #31、--pending-reviews 時のみ設定）
    :pending_reviews
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t() | nil,
          repo_name: String.t(),
          repo_type: String.t() | nil,
          type: String.t() | nil,
          status: atom() | nil,
          protection_status: atom() | nil,
          exists: boolean() | nil,
          last_push: String.t() | nil,
          visibility: String.t() | nil,
          default_branch: String.t() | nil,
          latest_branch: String.t() | nil,
          updated_at: String.t() | nil,
          pending_reviews: non_neg_integer() | nil
        }

  @doc """
  学生IDが有効かチェック
  """
  def valid_id?(id) do
    Regex.match?(~r/^k\d{2}(rs|jk|gjk)\d+$/, id)
  end

  @doc """
  学生IDからリポジトリ名を決定
  """
  def determine_repo_name(student_id) do
    cond do
      Regex.match?(~r/^k\d{2}(rs|jk)\d+$/, student_id) ->
        "#{student_id}-sotsuron"

      Regex.match?(~r/^k\d{2}gjk\d+$/, student_id) ->
        "#{student_id}-master"

      true ->
        nil
    end
  end

  @doc """
  最終更新日をフォーマット（JST時刻付き）
  """
  def format_last_update(%__MODULE__{last_push: nil}), do: "N/A"

  def format_last_update(%__MODULE__{last_push: last_push}) do
    case DateTime.from_iso8601(last_push) do
      {:ok, datetime, _} ->
        # UTCからJST(UTC+9)に変換
        jst_datetime = DateTime.add(datetime, 9, :hour)

        date_str = jst_datetime |> DateTime.to_date() |> Date.to_string()
        time_str = jst_datetime |> DateTime.to_time() |> Time.to_string() |> String.slice(0, 5)

        "#{date_str} #{time_str}"

      _ ->
        "N/A"
    end
  end

  @doc """
  ブランチ保護状態のアイコンを取得
  """
  def protection_icon(%__MODULE__{protection_status: :protected}), do: "✅"
  def protection_icon(%__MODULE__{protection_status: :unprotected}), do: "❌"
  def protection_icon(_), do: "❓"

  @doc """
  リポジトリ状態を取得
  リポジトリタイプに応じて適切な状態表示を行う
  """
  def repo_status(%__MODULE__{exists: false}), do: "Not Found"

  def repo_status(%__MODULE__{status: status, repo_type: repo_type, exists: true})
      when is_atom(status) do
    format_status_by_type(Atom.to_string(status), repo_type)
  end

  def repo_status(%__MODULE__{status: status, repo_type: repo_type, exists: true})
      when is_binary(status) do
    format_status_by_type(status, repo_type)
  end

  def repo_status(%__MODULE__{exists: true}), do: "Active"
  def repo_status(_), do: "Unknown"

  @doc """
  名前を指定した文字数で切り詰め
  日本語文字は2バイト幅として計算
  """
  def format_name(%__MODULE__{name: nil}, _opts), do: "N/A"

  def format_name(%__MODULE__{name: name}, opts) when is_binary(name) do
    if opts[:fullname] do
      name
    else
      # Name列の幅16文字なので、日本語文字8文字まで表示可能
      # 表示幅ベースで切り詰め（日本語=2幅、ASCII=1幅）
      # "…"の分を考慮して15幅に制限
      truncate_name_by_width(name, 15)
    end
  end

  # 表示幅を考慮した名前の切り詰め（日本語は2倍幅）
  defp truncate_name_by_width(name, max_width) do
    total_width = calculate_display_width(name)

    # 名前の表示幅が制限以下なら切り詰めない
    if total_width <= max_width do
      name
    else
      chars = String.graphemes(name)

      {result_chars, _current_width} =
        Enum.reduce_while(chars, {[], 0}, &reduce_char_width(&1, &2, max_width))

      result_chars |> Enum.reverse() |> Enum.join("") |> Kernel.<>("…")
    end
  end

  # 文字幅を考慮した文字の処理
  defp reduce_char_width(char, {acc_chars, acc_width}, max_width) do
    char_width = if String.match?(char, ~r/[^\x00-\x7F]/), do: 2, else: 1
    new_width = acc_width + char_width

    # "…"の分（1文字幅）を考慮
    if new_width + 1 > max_width do
      {:halt, {acc_chars, acc_width}}
    else
      {:cont, {[char | acc_chars], new_width}}
    end
  end

  # 文字列の表示幅を計算（日本語は2倍幅）
  defp calculate_display_width(string) do
    string
    |> String.graphemes()
    |> Enum.reduce(0, fn char, acc ->
      char_width = if String.match?(char, ~r/[^\x00-\x7F]/), do: 2, else: 1
      acc + char_width
    end)
  end

  # リポジトリタイプに応じてステータスを適切にフォーマット
  defp format_status_by_type("completed", "wr"), do: "Active"
  defp format_status_by_type("completed", "sotsuron"), do: "Completed"
  defp format_status_by_type("completed", "master"), do: "Completed"
  defp format_status_by_type("completed", "ise-report"), do: "Completed"
  defp format_status_by_type("active", _), do: "Active"
  defp format_status_by_type("inactive", _), do: "Inactive"
  defp format_status_by_type(status, _), do: String.capitalize(status)
end
