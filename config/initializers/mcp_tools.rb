# Be sure to restart your server when you modify this file.
#
# Registers the MCP tool catalog into the McpTools registry with each tool's
# required OAuth scope. The registry drives both `tools/list` filtering
# (presentation) and the controller's pre-dispatch scope enforcement (a write
# tool called with a read-only token is a 403 step-up, not an unknown-tool error).
#
# Runs inside `to_prepare` so the autoloaded tool constants are referenced (and
# thus loaded) on boot and re-registered after each code reload in development;
# `register` overwrites, so this is idempotent.
Rails.application.config.to_prepare do
  McpTools.register(McpTools::CreatePaste, scope: McpTools::WRITE_SCOPE)
  McpTools.register(McpTools::UpdatePaste, scope: McpTools::WRITE_SCOPE)
  McpTools.register(McpTools::ConfigurePaste, scope: McpTools::WRITE_SCOPE)
  McpTools.register(McpTools::GetPaste, scope: McpTools::READ_SCOPE)
  McpTools.register(McpTools::GetPasteStats, scope: McpTools::READ_SCOPE)
  McpTools.register(McpTools::ListPastes, scope: McpTools::READ_SCOPE)
  McpTools.register(McpTools::ListFolders, scope: McpTools::READ_SCOPE)
  McpTools.register(McpTools::CreateFolder, scope: McpTools::WRITE_SCOPE)
  McpTools.register(McpTools::RenameFolder, scope: McpTools::WRITE_SCOPE)
  McpTools.register(McpTools::DeleteFolder, scope: McpTools::WRITE_SCOPE)
end
