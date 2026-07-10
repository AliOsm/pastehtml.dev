require "test_helper"

class McpTools::UpdatePasteTest < ActiveSupport::TestCase
  setup do
    @alice = users(:alice)
    @bob = users(:bob)
    @ctx = { user: @alice }
  end

  test "html content republishes verbatim and returns the paste detail without folder_created" do
    paste = create_paste_for(@alice, "<title>Old</title><p>old</p>", filename: "paste.html")

    response = update(token: paste.token, content: "<title>New</title><p>new</p>", format: "html")

    assert_not response.error?
    paste.reload
    assert_equal "<title>New</title><p>new</p>", paste.content
    assert_equal "New", response.structured_content[:title]
    assert_not response.structured_content.key?(:folder_created)
  end

  test "markdown content is rendered to branded HTML, not stored raw" do
    paste = create_paste_for(@alice, "<p>old</p>", filename: "paste.html")

    response = update(token: paste.token, content: "# Heading\n\nbody", format: "markdown")

    assert_not response.error?
    paste.reload
    assert_includes paste.content, "md-body"
    assert_includes paste.content, "<h1"
    assert_not_includes paste.content, "# Heading"
  end

  test "updating an old markdown-sourced paste with format html stores the new content verbatim, never through the markdown renderer" do
    created = McpTools::CreatePaste.call(content: "# Original\n\nbody", format: "markdown", server_context: @ctx)
    token = created.structured_content[:token]
    paste = Paste.find_by(token: token)
    assert_equal "paste.md", paste.original_filename, "sanity check: the paste's stored filename is markdown"

    response = update(token: token, content: "<p># Not a heading, just text</p>", format: "html")

    assert_not response.error?
    paste.reload
    assert_equal "<p># Not a heading, just text</p>", paste.content, "format: html must drive rendering, not the paste's stored .md filename"
    assert_not_includes paste.content, "<h1"
    assert_equal "paste.html", paste.original_filename
  end

  test "a missing filename synthesizes one that agrees with format" do
    paste = create_paste_for(@alice, "<p>old</p>", filename: "paste.html")

    update(token: paste.token, content: "# x", format: "markdown")

    assert_equal "paste.md", paste.reload.original_filename
  end

  test "a supplied filename whose extension disagrees with format is an error and does not update the paste" do
    paste = create_paste_for(@alice, "<p>old</p>", filename: "paste.html")

    response = update(token: paste.token, content: "<p>new</p>", format: "html", filename: "note.md")

    assert response.error?
    assert_equal "filename_format_mismatch", response.structured_content[:code]
    assert_equal "filename", response.structured_content[:field]
    assert_equal "<p>old</p>", paste.reload.content
  end

  test "a token belonging to another user is a not-found error" do
    theirs = create_paste_for(@bob, "<p>bob's</p>", filename: "paste.html")

    response = update(token: theirs.token, content: "<p>hijacked</p>", format: "html")

    assert response.error?
    assert_equal "paste_not_found", response.structured_content[:code]
    assert_equal "token", response.structured_content[:field]
    assert_equal "<p>bob's</p>", theirs.reload.content
  end

  test "an unknown token is a not-found error" do
    response = update(token: "does-not-exist", content: "<p>x</p>", format: "html")

    assert response.error?
    assert_equal "paste_not_found", response.structured_content[:code]
  end

  test "content over the size limit is a validation error and does not persist" do
    paste = create_paste_for(@alice, "<p>old</p>", filename: "paste.html")
    oversized = "a" * (Paste::MAX_CONTENT_BYTES + 1)

    response = update(token: paste.token, content: oversized, format: "html")

    assert response.error?
    assert_equal "validation_failed", response.structured_content[:code]
    assert_equal "content", response.structured_content[:field]
    assert_equal "<p>old</p>", paste.reload.content
  end

  test "annotations mark it destructive, non-idempotent, non-read-only, closed-world" do
    annotations = McpTools::UpdatePaste.annotations_value

    assert_equal false, annotations.read_only_hint
    assert_equal true, annotations.destructive_hint
    assert_equal false, annotations.idempotent_hint
    assert_equal false, annotations.open_world_hint
  end

  private
    def update(**args)
      McpTools::UpdatePaste.call(**args, server_context: @ctx)
    end

    def create_paste_for(user, content, filename:)
      Paste.create!(content: content, original_filename: filename, user: user)
    end
end
