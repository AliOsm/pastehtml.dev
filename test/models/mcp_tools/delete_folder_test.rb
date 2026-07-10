require "test_helper"

class McpTools::DeleteFolderTest < ActiveSupport::TestCase
  setup do
    @alice = users(:alice)
    @bob = users(:bob)
    @ctx = { user: @alice }
  end

  test "confirm: false is refused and the folder survives untouched" do
    folder = @alice.folders.create!(name: "Keep Me")
    paste = Paste.create!(content: "<p>x</p>", original_filename: "p.html", user: @alice, folder: folder)

    response = delete(folder_id: folder.id, confirm: false)

    assert response.error?
    assert_equal "confirmation_required", response.structured_content[:code]
    assert_equal "confirm", response.structured_content[:field]
    assert Folder.exists?(folder.id)
    assert_equal folder.id, paste.reload.folder_id
  end

  test "omitting a truthy confirm value is refused" do
    folder = @alice.folders.create!(name: "Keep Me Too")

    response = delete(folder_id: folder.id, confirm: "nope")

    assert response.error?
    assert_equal "confirmation_required", response.structured_content[:code]
    assert Folder.exists?(folder.id)
  end

  test "confirm: true destroys the folder, unfiles its pastes (which survive), and revokes scoped API keys" do
    folder = folders(:projects)
    scoped_key = api_keys(:alice_projects_key)
    assert scoped_key.active?, "sanity check: the fixture key starts active"

    paste_one = Paste.create!(content: "<p>1</p>", original_filename: "p.html", user: @alice, folder: folder)
    paste_two = Paste.create!(content: "<p>2</p>", original_filename: "p.html", user: @alice, folder: folder)

    response = delete(folder_id: folder.id, confirm: true)

    assert_not response.error?
    structured = response.structured_content
    assert_equal true, structured[:deleted]
    assert_equal 2, structured[:unfiled_pastes_count]
    assert_equal 1, structured[:revoked_api_keys_count]

    assert_not Folder.exists?(folder.id)

    assert Paste.exists?(paste_one.id), "pastes must survive -- they can never be deleted"
    assert Paste.exists?(paste_two.id)
    assert_nil paste_one.reload.folder_id
    assert_nil paste_two.reload.folder_id

    assert scoped_key.reload.revoked?
  end

  test "a folder_id belonging to another user is a not-found error" do
    response = delete(folder_id: folders(:bob_notes).id, confirm: true)

    assert response.error?
    assert_equal "folder_not_found", response.structured_content[:code]
    assert_equal "folder_id", response.structured_content[:field]
    assert Folder.exists?(folders(:bob_notes).id)
  end

  test "an unknown folder_id is a not-found error" do
    response = delete(folder_id: 999_999, confirm: true)

    assert response.error?
    assert_equal "folder_not_found", response.structured_content[:code]
  end

  test "annotations mark it destructive, non-idempotent, non-read-only, closed-world" do
    annotations = McpTools::DeleteFolder.annotations_value

    assert_equal false, annotations.read_only_hint
    assert_equal true, annotations.destructive_hint
    assert_equal false, annotations.idempotent_hint
    assert_equal false, annotations.open_world_hint
  end

  private
    def delete(**args)
      McpTools::DeleteFolder.call(**args, server_context: @ctx)
    end
end
