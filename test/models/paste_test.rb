require "test_helper"

class PasteTest < ActiveSupport::TestCase
  test "generates a hard-to-guess token on create" do
    paste = create_paste

    assert_match(/\A[a-z0-9]{#{Paste::TOKEN_LENGTH}}\z/o, paste.token)
  end

  test "generates distinct tokens for each paste" do
    assert_not_equal create_paste.token, create_paste.token
  end

  test "uses the token in urls" do
    paste = create_paste

    assert_equal paste.token, paste.to_param
  end

  test "requires content" do
    paste = Paste.new(content: "", original_filename: "index.html")

    assert_not paste.valid?
    assert paste.errors[:content].any?
  end

  test "rejects content larger than the size limit" do
    paste = Paste.new(content: "a" * (Paste::MAX_CONTENT_BYTES + 1), original_filename: "index.html")

    assert_not paste.valid?
    assert paste.errors[:content].any?
  end

  test "requires an html filename" do
    paste = Paste.new(content: "<h1>Hi</h1>", original_filename: "notes.txt")

    assert_not paste.valid?
    assert paste.errors[:original_filename].any?
  end

  test "accepts .html and .htm filenames" do
    assert Paste.new(content: "<h1>Hi</h1>", original_filename: "index.html").valid?
    assert Paste.new(content: "<h1>Hi</h1>", original_filename: "INDEX.HTM").valid?
  end

  test "cannot be destroyed" do
    paste = create_paste

    assert_raises(ActiveRecord::ReadOnlyRecord) { paste.destroy! }
  end

  test "reveals a hard-to-guess update token once and stores only its digest" do
    paste = create_paste

    assert_match(/\A[1-9A-HJ-NP-Za-km-z]{32}\z/, paste.update_token)
    assert_equal Paste.digest_update_token(paste.update_token), paste.update_token_digest
    assert_nil Paste.find(paste.id).update_token
  end

  test "authorizes updates only with the matching update token" do
    paste = create_paste

    assert paste.updatable_with?(paste.update_token)
    assert_not paste.updatable_with?("wrong-token")
    assert_not paste.updatable_with?(nil)
    assert_not paste.updatable_with?("")
  end

  test "pastes without a stored digest are never updatable" do
    assert_not pastes(:hello).updatable_with?("anything")
  end

  test "republish replaces content and re-extracts the title" do
    paste = create_paste(content: "<title>Before</title>")

    assert paste.republish(content: "<title>After</title><p>v2</p>", original_filename: "v2.html")
    paste.reload

    assert_equal "After", paste.title
    assert_equal "v2.html", paste.original_filename
    assert_includes paste.content, "v2"
    assert_predicate paste, :updated?
  end

  test "republish keeps the filename when none is given" do
    paste = create_paste(original_filename: "keep.html")

    paste.republish(content: "<p>v2</p>")

    assert_equal "keep.html", paste.reload.original_filename
  end

  test "republish still validates content" do
    paste = create_paste

    assert_not paste.republish(content: "")
    assert paste.errors[:content].any?
  end

  test "from_upload builds a paste from an uploaded file" do
    upload = Rack::Test::UploadedFile.new(
      StringIO.new("<h1>Hello</h1>"), "text/html", original_filename: "hello.html"
    )

    paste = Paste.from_upload(upload)

    assert_equal "<h1>Hello</h1>", paste.content
    assert_equal "hello.html", paste.original_filename
    assert_equal Encoding::UTF_8, paste.content.encoding
  end

  test "extracts the document title on create" do
    paste = create_paste(content: "<html><head><title>  Auth &amp; Sessions\n RFC </title></head></html>")

    assert_equal "Auth & Sessions RFC", paste.title
    assert_equal "Auth & Sessions RFC", paste.display_title
  end

  test "falls back to the filename when there is no title" do
    paste = create_paste(content: "<p>No head here</p>", original_filename: "plan.html")

    assert_nil paste.title
    assert_equal "plan.html", paste.display_title
  end

  test "truncates extracted titles" do
    paste = create_paste(content: "<title>#{"long " * 60}</title>")

    assert paste.title.length <= Paste::MAX_TITLE_LENGTH
  end

  test "converts its html content to markdown" do
    paste = create_paste(content: "<h1>Title</h1><p>Hello <strong>world</strong></p><ul><li>one</li><li>two</li></ul>")

    markdown = paste.to_markdown

    assert_includes markdown, "# Title"
    assert_includes markdown, "**world**"
    assert_includes markdown, "- one"
    assert_includes markdown, "- two"
  end

  test "to_markdown does not raise on malformed html" do
    paste = create_paste(content: "<p>unterminated <strong>bold")

    assert_nothing_raised { paste.to_markdown }
  end

  test "accepts .md and .markdown filenames" do
    assert Paste.new(content: "<h1>Hi</h1>", original_filename: "notes.md").valid?
    assert Paste.new(content: "<h1>Hi</h1>", original_filename: "notes.markdown").valid?
  end

  test "from_upload renders a markdown upload into a branded html page" do
    upload = Rack::Test::UploadedFile.new(
      StringIO.new("# Title\n\nHello **world**"), "text/markdown", original_filename: "notes.md"
    )

    paste = Paste.from_upload(upload)

    assert_equal "notes.md", paste.original_filename
    assert_includes paste.content, 'class="md-body"'
    assert_includes paste.content, "<strong>world</strong>"
    assert paste.valid?
  end

  test "extracts the title from a rendered markdown upload" do
    upload = Rack::Test::UploadedFile.new(
      StringIO.new("# The Heading\n\nbody"), "text/markdown", original_filename: "notes.md"
    )

    paste = Paste.from_upload(upload)
    paste.save!

    assert_equal "The Heading", paste.title
  end

  test "render_content leaves html uploads untouched" do
    assert_equal "<h1>Hi</h1>", Paste.render_content("<h1>Hi</h1>", "page.html")
  end

  test "republish re-renders when the paste originated from markdown" do
    paste = Paste.create!(content: Paste.render_content("# One", "doc.md"), original_filename: "doc.md")
    assert_includes paste.content, ">One</h1>"

    paste.republish(content: "# Two")

    assert_includes paste.reload.content, ">Two</h1>"
    assert_includes paste.content, 'class="md-body"'
  end

  test "from_upload scrubs invalid utf-8 bytes" do
    upload = Rack::Test::UploadedFile.new(
      StringIO.new("<p>caf\xE9</p>".b), "text/html", original_filename: "cafe.html"
    )

    paste = Paste.from_upload(upload)

    assert_predicate paste.content, :valid_encoding?
  end

  private
    def create_paste(content: "<h1>Hello</h1>", original_filename: "hello.html")
      Paste.create!(content:, original_filename:)
    end
end
