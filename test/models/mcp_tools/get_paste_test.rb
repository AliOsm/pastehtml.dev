require "test_helper"

class McpTools::GetPasteTest < ActiveSupport::TestCase
  setup do
    @alice = users(:alice)
    @bob = users(:bob)
    @ctx = { user: @alice }
  end

  test "returns the paste detail plus stored content and content_bytes" do
    paste = Paste.create!(content: "<title>Report</title><p>hi</p>", original_filename: "paste.html", user: @alice)

    response = get(token: paste.token)

    assert_not response.error?
    structured = response.structured_content
    assert_equal paste.token, structured[:token]
    assert_equal "Report", structured[:title]
    assert_equal "<title>Report</title><p>hi</p>", structured[:content]
    assert_equal "<title>Report</title><p>hi</p>".bytesize, structured[:content_bytes]
    assert_not structured.key?(:markdown)
  end

  test "content is the stored HTML for a markdown-created paste, never the original Markdown source" do
    created = McpTools::CreatePaste.call(content: "# Heading\n\nbody text", format: "markdown", server_context: @ctx)
    token = created.structured_content[:token]

    response = get(token: token)

    assert_not response.error?
    assert_includes response.structured_content[:content], "<h1"
    assert_not_includes response.structured_content[:content], "# Heading"
  end

  test "include_markdown returns a best-effort conversion alongside the stored HTML" do
    paste = Paste.create!(content: "<h1>Title</h1><p>hi</p>", original_filename: "paste.html", user: @alice)

    response = get(token: paste.token, include_markdown: true)

    assert_not response.error?
    assert_includes response.structured_content[:content], "<h1>Title</h1>"
    assert_includes response.structured_content[:markdown], "Title"
    assert_not_includes response.structured_content[:markdown], "<h1>"
  end

  test "a token belonging to another user is a not-found error" do
    theirs = Paste.create!(content: "<p>bob's</p>", original_filename: "paste.html", user: @bob)

    response = get(token: theirs.token)

    assert response.error?
    assert_equal "paste_not_found", response.structured_content[:code]
    assert_equal "token", response.structured_content[:field]
  end

  test "an unknown token is a not-found error" do
    response = get(token: "does-not-exist")

    assert response.error?
    assert_equal "paste_not_found", response.structured_content[:code]
  end

  test "annotations mark it read-only, idempotent, non-destructive, closed-world" do
    annotations = McpTools::GetPaste.annotations_value

    assert_equal true, annotations.read_only_hint
    assert_equal false, annotations.destructive_hint
    assert_equal true, annotations.idempotent_hint
    assert_equal false, annotations.open_world_hint
  end

  private
    def get(**args)
      McpTools::GetPaste.call(**args, server_context: @ctx)
    end
end
