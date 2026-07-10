require "test_helper"

class McpTools::RenameFolderTest < ActiveSupport::TestCase
  setup do
    @alice = users(:alice)
    @bob = users(:bob)
    @ctx = { user: @alice }
  end

  test "renames a folder owned by the user and reports its paste count" do
    folder = @alice.folders.create!(name: "Old Name")
    Paste.create!(content: "<p>x</p>", original_filename: "p.html", user: @alice, folder: folder)

    response = rename(folder_id: folder.id, name: "New Name")

    assert_not response.error?
    structured = response.structured_content
    assert_equal folder.id, structured[:id]
    assert_equal "New Name", structured[:name]
    assert_equal 1, structured[:pastes_count]
    assert_equal "New Name", folder.reload.name
  end

  test "a duplicate name (case-insensitive) is a validation error" do
    @alice.folders.create!(name: "Taken")
    folder = @alice.folders.create!(name: "Renameable")

    response = rename(folder_id: folder.id, name: "taken")

    assert response.error?
    assert_equal "validation_failed", response.structured_content[:code]
    assert_equal "name", response.structured_content[:field]
    assert_equal "Renameable", folder.reload.name
  end

  test "a folder_id belonging to another user is a not-found error" do
    response = rename(folder_id: folders(:bob_notes).id, name: "Hijacked")

    assert response.error?
    assert_equal "folder_not_found", response.structured_content[:code]
    assert_equal "folder_id", response.structured_content[:field]
  end

  test "an unknown folder_id is a not-found error" do
    response = rename(folder_id: 999_999, name: "Nope")

    assert response.error?
    assert_equal "folder_not_found", response.structured_content[:code]
  end

  test "annotations mark it a write, idempotent, non-destructive, closed-world tool" do
    annotations = McpTools::RenameFolder.annotations_value

    assert_equal false, annotations.read_only_hint
    assert_equal false, annotations.destructive_hint
    assert_equal true, annotations.idempotent_hint
    assert_equal false, annotations.open_world_hint
  end

  private
    def rename(**args)
      McpTools::RenameFolder.call(**args, server_context: @ctx)
    end
end
