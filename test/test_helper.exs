ExUnit.start()

# CLI の exit_with_code をテストから検証できるよう、System.halt の代わりに
# throw({:cli_test_exit, code}) させる（ToolKit.CLI.Exit の test_mode 規約）
Application.put_env(:thesis_monitor, :test_mode, true)
