require "test_helper"

class McpTools::ListPastesTest < ActiveSupport::TestCase
  setup do
    @alice = users(:alice)
    @bob = users(:bob)
    @ctx = { user: @alice }
  end

  test "lists the user's pastes newest first" do
    first = create_paste_for(@alice, "<p>1</p>")
    second = create_paste_for(@alice, "<p>2</p>")
    third = create_paste_for(@alice, "<p>3</p>")

    tokens = list.structured_content[:pastes].map { |paste| paste[:token] }

    assert_equal [ third.token, second.token, first.token ], tokens
  end

  test "does not include another user's pastes" do
    mine = create_paste_for(@alice, "<p>mine</p>")
    theirs = create_paste_for(@bob, "<p>theirs</p>")

    tokens = list.structured_content[:pastes].map { |paste| paste[:token] }

    assert_includes tokens, mine.token
    assert_not_includes tokens, theirs.token
    assert_equal 1, list.structured_content[:total_count]
  end

  test "filters by folder id" do
    folder = @alice.folders.create!(name: "Filtered")
    inside = create_paste_for(@alice, "<p>in</p>", folder: folder)
    create_paste_for(@alice, "<p>out</p>")

    result = list(folder_id: folder.id)

    tokens = result.structured_content[:pastes].map { |paste| paste[:token] }
    assert_equal [ inside.token ], tokens
    assert_equal 1, result.structured_content[:total_count]
  end

  test "filters by folder name" do
    folder = @alice.folders.create!(name: "Named Filter")
    inside = create_paste_for(@alice, "<p>in</p>", folder: folder)
    create_paste_for(@alice, "<p>out</p>")

    tokens = list(folder_name: "named filter").structured_content[:pastes].map { |paste| paste[:token] }

    assert_equal [ inside.token ], tokens
  end

  test "an unknown folder id is an error, not an empty list" do
    result = list(folder_id: 999_999)

    assert result.error?
    assert_equal "folder_not_found", result.structured_content[:code]
    assert_equal "folder_id", result.structured_content[:field]
  end

  test "an unknown folder name is an error" do
    result = list(folder_name: "no such folder")

    assert result.error?
    assert_equal "folder_not_found", result.structured_content[:code]
    assert_equal "folder_name", result.structured_content[:field]
  end

  test "paginates with a fixed page size of 20, newest first across pages" do
    21.times { |i| create_paste_for(@alice, "<p>#{i}</p>") }

    first_page = list(page: 1).structured_content
    assert_equal 20, first_page[:pastes].length
    assert_equal 1, first_page[:page]
    assert_equal 21, first_page[:total_count]

    second_page = list(page: 2).structured_content
    assert_equal 1, second_page[:pastes].length
    assert_equal 2, second_page[:page]
    assert_equal 21, second_page[:total_count]
  end

  test "a page past the end is empty but still reports the total" do
    create_paste_for(@alice, "<p>only</p>")

    result = list(page: 5).structured_content

    assert_empty result[:pastes]
    assert_equal 1, result[:total_count]
  end

  test "reports each paste's content byte size without loading the body" do
    paste = create_paste_for(@alice, "<p>measured</p>")

    summary = list.structured_content[:pastes].first

    assert_equal paste.content.bytesize, summary[:content_bytes]
    assert summary[:content_bytes].positive?
  end

  test "an absurdly large page is clamped instead of overflowing the SQL offset" do
    # Without clamping this reaches Postgres as an out-of-range bigint OFFSET and
    # raises PG::NumericValueOutOfRange, whose message the MCP gem would leak.
    response = list(page: 10**18)

    assert_not response.error?, "a huge page must not raise; it should clamp and return empty"
    assert_equal McpTools::ListPastes::MAX_PAGE, response.structured_content[:page]
    assert_empty response.structured_content[:pastes]
  end

  test "a non-positive page is normalized to the first page" do
    create_paste_for(@alice, "<p>x</p>")

    response = list(page: -5)

    assert_not response.error?
    assert_equal 1, response.structured_content[:page]
  end

  private
    def list(**args)
      McpTools::ListPastes.call(**args, server_context: @ctx)
    end

    def create_paste_for(user, content, folder: nil)
      Paste.create!(content: content, original_filename: "p.html", user: user, folder: folder)
    end
end
