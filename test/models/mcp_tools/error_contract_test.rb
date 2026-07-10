require "test_helper"

# Every tool's domain failures come out of the shared BaseTool helper, so their
# error responses are one stable shape across tools: an SDK error response whose
# structuredContent is { code, message, field? }.
class McpTools::ErrorContractTest < ActiveSupport::TestCase
  setup do
    @ctx = { user: users(:alice) }
  end

  test "field-bearing errors from different tools share an identical key set" do
    from_create = McpTools::CreatePaste.call(
      content: "<p>x</p>", format: "html", filename: "note.md", server_context: @ctx
    )
    from_list = McpTools::ListPastes.call(folder_id: 999_999, server_context: @ctx)

    assert from_create.error?
    assert from_list.error?
    assert_equal %i[ code field message ], from_create.structured_content.keys.sort
    assert_equal from_create.structured_content.keys.sort, from_list.structured_content.keys.sort
  end

  test "every error carries a machine code and a human message" do
    error = McpTools::ListPastes.call(folder_name: "nope", server_context: @ctx)

    assert error.error?
    assert error.structured_content[:code].is_a?(String)
    assert error.structured_content[:message].is_a?(String)
    assert error.structured_content[:message].present?
  end
end
