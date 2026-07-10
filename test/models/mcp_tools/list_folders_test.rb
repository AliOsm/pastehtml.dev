require "test_helper"

class McpTools::ListFoldersTest < ActiveSupport::TestCase
  setup do
    @alice = users(:alice)
    @bob = users(:bob)
    @ctx = { user: @alice }
  end

  test "lists the user's folders ordered by name, case-insensitively" do
    @alice.folders.create!(name: "beta")
    @alice.folders.create!(name: "Alpha")

    names = list.structured_content[:folders].map { |folder| folder[:name] }

    # "Projects" comes from the fixture; ordering is by LOWER(name).
    assert_equal [ "Alpha", "beta", "Projects" ], names
  end

  test "excludes other users' folders" do
    names = list.structured_content[:folders].map { |folder| folder[:name] }

    assert_not_includes names, folders(:bob_notes).name
  end

  test "reports the paste count per folder" do
    folder = @alice.folders.create!(name: "Counted")
    2.times { Paste.create!(content: "<p>x</p>", original_filename: "p.html", user: @alice, folder: folder) }
    Paste.create!(content: "<p>unfiled</p>", original_filename: "p.html", user: @alice)

    counted = list.structured_content[:folders].find { |f| f[:name] == "Counted" }
    projects = list.structured_content[:folders].find { |f| f[:name] == "Projects" }

    assert_equal 2, counted[:pastes_count]
    assert_equal 0, projects[:pastes_count]
  end

  private
    def list
      McpTools::ListFolders.call(server_context: @ctx)
    end
end
