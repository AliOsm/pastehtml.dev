require "test_helper"

# The McpTools registry's scope model: one read scope plus per-resource-group
# write scopes (never a catch-all write), and every real tool registered under
# the narrowest scope its operations need.
class McpToolsTest < ActiveSupport::TestCase
  test "the scope catalog is read plus per-resource-group writes" do
    assert_equal "mcp:read", McpTools::READ_SCOPE
    assert_equal "mcp:pastes:write", McpTools::PASTES_WRITE_SCOPE
    assert_equal "mcp:folders:write", McpTools::FOLDERS_WRITE_SCOPE
    assert_equal %w[mcp:pastes:write mcp:folders:write], McpTools::WRITE_SCOPES
    assert_equal %w[mcp:read mcp:pastes:write mcp:folders:write], McpTools::ALL_SCOPES
  end

  test "paste-mutating tools require the pastes write scope" do
    %w[create_paste update_paste configure_paste].each do |tool|
      assert_equal McpTools::PASTES_WRITE_SCOPE, McpTools.required_scope(tool), tool
    end
  end

  test "folder-mutating tools require the folders write scope" do
    %w[create_folder rename_folder delete_folder].each do |tool|
      assert_equal McpTools::FOLDERS_WRITE_SCOPE, McpTools.required_scope(tool), tool
    end
  end

  test "read-only tools require only the read scope" do
    %w[get_paste get_paste_stats list_pastes list_folders].each do |tool|
      assert_equal McpTools::READ_SCOPE, McpTools.required_scope(tool), tool
    end
  end

  test "the retired catch-all mcp:write is no longer registrable" do
    tool = Class.new(MCP::Tool) { tool_name "fake_legacy_write" }

    assert_raises(ArgumentError) { McpTools.register(tool, scope: "mcp:write") }
  ensure
    McpTools.deregister(tool)
  end
end
