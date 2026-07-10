require "test_helper"

class McpTools::CreatePasteTest < ActiveSupport::TestCase
  setup do
    @alice = users(:alice)
    @bob = users(:bob)
    @ctx = { user: @alice }
  end

  test "html content is stored verbatim, owned by the token user, with a title" do
    response = create(content: "<title>Report</title><p>hi</p>", format: "html")

    assert_not response.error?
    paste = Paste.find_by(token: response.structured_content[:token])
    assert_equal @alice, paste.user
    assert_equal "<title>Report</title><p>hi</p>", paste.content
    assert_equal "Report", response.structured_content[:title]
    assert_equal false, response.structured_content[:password_protected]
    assert_nil response.structured_content[:folder]
  end

  test "markdown content is rendered to branded HTML, not stored raw" do
    response = create(content: "# Heading\n\nbody text", format: "markdown")

    assert_not response.error?
    paste = Paste.find_by(token: response.structured_content[:token])
    assert_includes paste.content, "md-body", "expected the branded Markdown wrapper"
    assert_includes paste.content, "<h1", "expected the heading to be rendered to HTML"
    assert_not_includes paste.content, "# Heading", "raw Markdown should not survive"
    assert_equal "Heading", response.structured_content[:title]
  end

  test "a missing filename synthesizes one that drives the right renderer" do
    html = create(content: "<p>x</p>", format: "html")
    assert_equal "paste.html", Paste.find_by(token: html.structured_content[:token]).original_filename

    markdown = create(content: "# x", format: "markdown")
    assert_equal "paste.md", Paste.find_by(token: markdown.structured_content[:token]).original_filename
  end

  test "a supplied filename whose extension disagrees with format is an error" do
    response = create(content: "<p>x</p>", format: "html", filename: "note.md")

    assert response.error?
    assert_equal "filename_format_mismatch", response.structured_content[:code]
    assert_equal "filename", response.structured_content[:field]

    reverse = create(content: "# x", format: "markdown", filename: "page.html")
    assert reverse.error?
    assert_equal "filename_format_mismatch", reverse.structured_content[:code]
  end

  test "an agreeing filename is accepted" do
    response = create(content: "# Title\n\nx", format: "markdown", filename: "guide.markdown")

    assert_not response.error?
    assert_equal "guide.markdown", Paste.find_by(token: response.structured_content[:token]).original_filename
  end

  test "folder_name auto-creates a missing folder and flags it" do
    assert_difference -> { @alice.folders.count }, 1 do
      @response = create(content: "<p>x</p>", format: "html", folder_name: "Fresh Folder")
    end

    assert_equal true, @response.structured_content[:folder_created]
    assert_equal "Fresh Folder", @response.structured_content.dig(:folder, :name)
    assert @alice.folders.exists?(name: "Fresh Folder")
  end

  test "folder_name reuses an existing folder case-insensitively without duplicating" do
    existing = @alice.folders.create!(name: "Work")

    assert_no_difference -> { @alice.folders.count } do
      @response = create(content: "<p>x</p>", format: "html", folder_name: "work")
    end

    assert_equal false, @response.structured_content[:folder_created]
    assert_equal existing.id, @response.structured_content.dig(:folder, :id)
  end

  test "a folder_id belonging to another user is an ownership (not-found) error" do
    response = create(content: "<p>x</p>", format: "html", folder_id: folders(:bob_notes).id)

    assert response.error?
    assert_equal "folder_not_found", response.structured_content[:code]
    assert_equal "folder_id", response.structured_content[:field]
  end

  test "folder_id and folder_name naming different folders is a conflict" do
    response = create(content: "<p>x</p>", format: "html", folder_id: folders(:projects).id, folder_name: "Something Else")

    assert response.error?
    assert_equal "folder_mismatch", response.structured_content[:code]
    assert_equal "folder_name", response.structured_content[:field]
  end

  test "an invalid custom_subdomain returns the error contract with the field" do
    response = create(content: "<p>x</p>", format: "html", custom_subdomain: "bad_sub")

    assert response.error?
    assert_equal "validation_failed", response.structured_content[:code]
    assert_equal "custom_subdomain", response.structured_content[:field]
  end

  test "content over the size limit is a validation error on the content field" do
    oversized = "a" * (Paste::MAX_CONTENT_BYTES + 1)

    assert_no_difference -> { Paste.count } do
      @response = create(content: oversized, format: "html")
    end

    assert @response.error?
    assert_equal "validation_failed", @response.structured_content[:code]
    assert_equal "content", @response.structured_content[:field]
  end

  test "a password sets password_protected" do
    response = create(content: "<p>x</p>", format: "html", password: "s3cret")

    assert_not response.error?
    assert_equal true, response.structured_content[:password_protected]
    assert Paste.find_by(token: response.structured_content[:token]).password_protected?
  end

  test "an auto-created folder is rolled back when the paste itself is invalid" do
    assert_no_difference -> { @alice.folders.count } do
      @response = create(content: "a" * (Paste::MAX_CONTENT_BYTES + 1), format: "html", folder_name: "Doomed")
    end

    assert @response.error?
    assert_not @alice.folders.exists?(name: "Doomed")
  end

  # A concurrent writer can take the same custom_subdomain between our validation
  # SELECT and the INSERT, so paste.save raises RecordNotUnique at the DB layer.
  # That race must surface as the same stable tool error, not a leaked exception.
  test "a custom_subdomain uniqueness race returns a stable error, not an exception" do
    response = simulating_uniqueness_race(Paste, :save) do
      create(content: "<p>x</p>", format: "html", custom_subdomain: "racy-sub")
    end

    assert response.error?
    assert_equal "validation_failed", response.structured_content[:code]
    assert_equal "custom_subdomain", response.structured_content[:field]
  end

  test "an auto-created folder is rolled back when a uniqueness race aborts the paste" do
    assert_no_difference -> { @alice.folders.count } do
      response = simulating_uniqueness_race(Paste, :save) do
        create(content: "<p>x</p>", format: "html", custom_subdomain: "racy-sub", folder_name: "Doomed By Race")
      end
      assert response.error?
    end

    assert_not @alice.folders.exists?(name: "Doomed By Race")
  end

  private
    def create(**args)
      McpTools::CreatePaste.call(**args, server_context: @ctx)
    end

    # Forces the next call to `method` on `klass` to raise RecordNotUnique once,
    # then restores the original. Mirrors the folder tool tests.
    def simulating_uniqueness_race(klass, method)
      defined_here = klass.instance_methods(false).include?(method)
      original = klass.instance_method(method)
      raised = false
      klass.send(:define_method, method) do |*args, **kwargs, &block|
        unless raised
          raised = true
          raise ActiveRecord::RecordNotUnique, "PG::UniqueViolation"
        end
        original.bind(self).call(*args, **kwargs, &block)
      end
      yield
    ensure
      defined_here ? klass.send(:define_method, method, original) : klass.send(:remove_method, method)
    end
end
