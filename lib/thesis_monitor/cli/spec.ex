defmodule ThesisMonitor.CLI.Spec do
  @moduledoc """
  CLI のコマンド・オプション定義の単一ソース。

  定義(オプションカタログ・コマンド表・enum)はこのモジュールが持ち、
  OptionParser に渡す strict/aliases、コマンドごとの有効オプション検証、
  enum 値の検証、help 文面の導出は `ToolKit.CLI.Spec` に委譲する。
  ここに定義がないオプションはパース段階でエラーになる。
  """

  alias ToolKit.CLI.Spec, as: EngineSpec

  # thesis は sotsuron ∪ master のフィルタ名、all は全件
  # (語彙は smkwlab/student-repo-management#471 の設計に従う)
  @type_filters [
    "wr",
    "ise",
    "sotsuron",
    "master",
    "thesis",
    "latex",
    "poster",
    "sotsuron-report",
    "other",
    "all"
  ]
  @output_formats ["table", "json", "csv"]

  @doc "リポジトリタイプフィルタの正準リスト（--type の enum）"
  def type_filters, do: @type_filters

  @doc "出力形式の正準リスト（--format の enum）"
  def output_formats, do: @output_formats

  @option_catalog %{
    help: %{type: :boolean, alias: :h, values: nil, doc: "このヘルプを表示"},
    verbose: %{type: :boolean, alias: :v, values: nil, doc: "詳細ログを表示"},
    config: %{type: :string, alias: :c, values: nil, doc: "設定ファイルのパスを上書き"},
    version: %{type: :boolean, alias: nil, values: nil, doc: "バージョン情報を表示"},
    format: %{type: :string, alias: nil, values: @output_formats, doc: "出力形式"},
    type: %{
      type: :string,
      alias: nil,
      values: @type_filters,
      doc: "リポジトリタイプで絞り込み（thesis は sotsuron∪master、all は全件）"
    },
    long: %{type: :boolean, alias: :l, values: nil, doc: "Type 列を含む詳細表示"},
    show_protection: %{type: :boolean, alias: nil, values: nil, doc: "ブランチ保護状況を表示"},
    show_status: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "リポジトリの存在状態（Active / Not Found）を表示"
    },
    pending_reviews: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "教員の返信待ちリポジトリを表示（API 追加取得のためオプトイン）"
    },
    fullname: %{type: :boolean, alias: nil, values: nil, doc: "名前の長い場合も切り詰めずに全文表示"},
    no_cache: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "キャッシュを読まず常に最新を取得（レジストリを書き換えた直後の確認用）"
    },
    show_archived: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "archive 済みリポジトリも一覧に表示（既定は現役のみ）"
    },
    # alias: :t が -t を受理させる（OptionParser は aliases 経由でのみ 1 文字形を解釈する）
    t: %{type: :boolean, alias: :t, values: nil, doc: "最終更新時刻順でソート"},
    reverse: %{type: :boolean, alias: :r, values: nil, doc: "ソート順を反転"},
    test: %{
      type: :boolean,
      alias: nil,
      values: nil,
      doc: "テスト用サンドボックス設定を生成（thesis-student-registry-test を使用）"
    },
    org: %{type: :string, alias: nil, values: nil, doc: "対象の GitHub organization"},
    registry_repo: %{
      type: :string,
      alias: nil,
      values: nil,
      doc: "レジストリデータリポジトリを上書き（owner/repo 形式）"
    },
    force: %{type: :boolean, alias: nil, values: nil, doc: "既存の設定ファイルを上書き"}
  }

  @global_option_names [:help, :verbose, :config, :version]

  @commands [
    %{
      name: "init",
      aliases: [],
      usage: ["init"],
      summary: "セットアップ（設定ファイル生成・doctor 検証）",
      options: [:test, :org, :registry_repo, :force],
      examples: ["init", "init --test", "init --org myorg --registry-repo myorg/my-registry"]
    },
    %{
      name: "status",
      aliases: [],
      usage: ["status"],
      summary: "全学生リポジトリの状態を表示（サブコマンド省略時の既定）",
      options: [
        :format,
        :type,
        :long,
        :show_protection,
        :show_status,
        :pending_reviews,
        :fullname,
        :no_cache,
        :show_archived,
        :t,
        :reverse
      ],
      examples: [
        "status",
        "status --show-protection",
        "status --type thesis",
        "status --type ise --pending-reviews",
        "status -t -r",
        "status --format json"
      ]
    },
    %{
      name: "activity",
      aliases: [],
      usage: ["activity [days]"],
      summary: "最近のコミット活動を表示（既定: 過去7日間）",
      options: [:format, :no_cache],
      examples: ["activity", "activity 14", "activity --format json"]
    },
    %{
      name: "pr-stats",
      aliases: [],
      usage: ["pr-stats"],
      summary: "PR/Issue統計を表示",
      options: [:format, :no_cache],
      examples: ["pr-stats", "pr-stats --verbose"]
    },
    %{
      name: "check",
      aliases: [],
      usage: ["check"],
      summary: "ブランチ保護設定を確認",
      options: [:no_cache],
      examples: ["check"]
    },
    %{
      name: "bulk",
      aliases: [],
      usage: ["bulk"],
      summary: "一括ブランチ保護設定（student-repo-management のスクリプトを案内）",
      options: [],
      examples: ["bulk"]
    },
    %{
      name: "search",
      aliases: [],
      usage: ["search <検索語>"],
      summary: "学生情報を検索・表示（学籍番号は完全一致・氏名は部分一致）",
      options: [:format, :fullname, :no_cache],
      examples: ["search k92rs004", "search \"田中\" --format json"]
    }
  ]

  @spec_struct %EngineSpec{
    tool_name: "thesis-monitor",
    tool_summary: "学生論文リポジトリ管理ツール",
    option_catalog: @option_catalog,
    global_option_names: @global_option_names,
    commands: @commands
  }

  @doc "ToolKit の CLI エンジンに渡す spec"
  def spec, do: @spec_struct

  @doc "コマンド定義の一覧"
  def commands, do: @commands

  @doc "コマンド名の一覧"
  def command_names, do: Enum.map(@commands, & &1.name)

  @doc "名前からコマンド定義を引く"
  def find_command(name), do: EngineSpec.find_command(@spec_struct, name)

  @doc "コマンドが受け付けるオプション名の MapSet（未知のコマンドは nil）"
  def allowed_for(name), do: EngineSpec.allowed_for(@spec_struct, name)

  @doc "グローバル help を spec から生成する"
  def render_help, do: EngineSpec.render_help(@spec_struct)

  @doc "コマンド単体の help を spec から生成する（未知のコマンドは nil）"
  def render_command_help(name), do: EngineSpec.render_command_help(@spec_struct, name)
end
