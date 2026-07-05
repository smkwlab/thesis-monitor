defmodule ThesisMonitor.MixProject do
  use Mix.Project

  def project do
    [
      app: :thesis_monitor,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: ThesisMonitor.CLI, name: "thesis-monitor"],
      test_coverage: [
        # 現状の実測 59% を下回らないための床。テスト拡充に合わせて引き上げる
        summary: [threshold: 55],
        ignore_modules: [
          # CLI層 - 外部コマンドライン依存
          ThesisMonitor.CLI,

          # 外部API依存コマンド - GitHub API必須
          ThesisMonitor.Commands.Activity,
          ThesisMonitor.Commands.Bulk,
          ThesisMonitor.Commands.Check,
          ThesisMonitor.Commands.PullRequestStats,

          # 外部依存システム
          ThesisMonitor.DataSource.GitHubAPI,
          ThesisMonitor.Output,
          ThesisMonitor.TokenManager
        ]
      ],
      dialyzer: [
        plt_add_apps: [:mix],
        flags: [:error_handling, :underspecs],
        ignore_warnings: "dialyzer.ignore-warnings"
      ],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req, "~> 0.4"},
      {:yaml_elixir, "~> 2.9"},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.0", only: :test}
    ]
  end
end
