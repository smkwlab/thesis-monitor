defmodule ThesisMonitor.Commands.Bulk do
  @moduledoc """
  一括ブランチ保護設定コマンド
  """

  alias ThesisMonitor.Output

  def run(args, _opts) do
    if "--help" in args do
      show_help()
    else
      Output.warn("Bulk branch protection setup is not yet implemented in escript version.")
      Output.info("Please use the original shell script for now:")
      Output.info("  cd ../thesis_management_tools")
      Output.info("  ./scripts/bulk-setup-protection.sh")
    end
  end

  defp show_help do
    IO.puts("""
    Bulk Branch Protection Setup

    This command sets up branch protection for multiple repositories.

    Note: This functionality is not yet implemented in the escript version.
    Please use the original shell script for bulk operations.

    Usage:
      cd ../thesis_management_tools
      ./scripts/bulk-setup-protection.sh
    """)
  end
end
