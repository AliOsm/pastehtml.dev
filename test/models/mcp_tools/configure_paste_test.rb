require "test_helper"

class McpTools::ConfigurePasteTest < ActiveSupport::TestCase
  setup do
    @alice = users(:alice)
    @bob = users(:bob)
    @ctx = { user: @alice }
  end

  test "sets a password" do
    paste = create_paste_for(@alice)

    response = configure(token: paste.token, password: "s3cret")

    assert_not response.error?
    assert_equal true, response.structured_content[:password_protected]
    assert paste.reload.password_protected?
  end

  test "clear_password actually clears password protection" do
    paste = create_paste_for(@alice, password: "s3cret")
    assert paste.password_protected?

    response = configure(token: paste.token, clear_password: true)

    assert_not response.error?
    assert_equal false, response.structured_content[:password_protected]
    assert_not paste.reload.password_protected?
  end

  test "replacing a custom_subdomain frees the old one" do
    paste = create_paste_for(@alice, custom_subdomain: "old-sub")
    assert Paste.exists?(custom_subdomain: "old-sub")

    response = configure(token: paste.token, custom_subdomain: "new-sub")

    assert_not response.error?
    assert_equal "new-sub", paste.reload.custom_subdomain
    assert_not Paste.exists?(custom_subdomain: "old-sub"), "the old subdomain must be released"
  end

  test "clear_custom_subdomain removes the custom subdomain" do
    paste = create_paste_for(@alice, custom_subdomain: "taken-sub")

    response = configure(token: paste.token, clear_custom_subdomain: true)

    assert_not response.error?
    assert_nil paste.reload.custom_subdomain
    assert_not Paste.exists?(custom_subdomain: "taken-sub")
  end

  test "moves a paste into a folder by id and clears it back out" do
    paste = create_paste_for(@alice)
    folder = @alice.folders.create!(name: "Target")

    moved = configure(token: paste.token, folder_id: folder.id)
    assert_not moved.error?
    assert_equal folder.id, paste.reload.folder_id
    assert_equal folder.id, moved.structured_content.dig(:folder, :id)

    cleared = configure(token: paste.token, clear_folder: true)
    assert_not cleared.error?
    assert_nil paste.reload.folder_id
    assert_nil cleared.structured_content[:folder]
  end

  test "folder_name auto-creates a missing folder and flags it" do
    paste = create_paste_for(@alice)

    assert_difference -> { @alice.folders.count }, 1 do
      @response = configure(token: paste.token, folder_name: "Fresh Folder")
    end

    assert_not @response.error?
    assert_equal true, @response.structured_content[:folder_created]
    assert_equal "Fresh Folder", @response.structured_content.dig(:folder, :name)
  end

  test "a folder_id belonging to another user is a not-found error" do
    paste = create_paste_for(@alice)

    response = configure(token: paste.token, folder_id: folders(:bob_notes).id)

    assert response.error?
    assert_equal "folder_not_found", response.structured_content[:code]
    assert_equal "folder_id", response.structured_content[:field]
  end

  test "content is left untouched" do
    paste = create_paste_for(@alice, content: "<p>untouched</p>")

    configure(token: paste.token, password: "s3cret")

    assert_equal "<p>untouched</p>", paste.reload.content
  end

  test "a token belonging to another user is a not-found error" do
    theirs = create_paste_for(@bob)

    response = configure(token: theirs.token, password: "hijack")

    assert response.error?
    assert_equal "paste_not_found", response.structured_content[:code]
    assert_equal "token", response.structured_content[:field]
  end

  test "no settings supplied is an error" do
    paste = create_paste_for(@alice)

    response = configure(token: paste.token)

    assert response.error?
    assert_equal "no_settings_provided", response.structured_content[:code]
  end

  test "password and clear_password together is a conflict" do
    paste = create_paste_for(@alice)

    response = configure(token: paste.token, password: "s3cret", clear_password: true)

    assert response.error?
    assert_equal "conflicting_arguments", response.structured_content[:code]
    assert_equal "clear_password", response.structured_content[:field]
  end

  test "custom_subdomain and clear_custom_subdomain together is a conflict" do
    paste = create_paste_for(@alice)

    response = configure(token: paste.token, custom_subdomain: "sub", clear_custom_subdomain: true)

    assert response.error?
    assert_equal "conflicting_arguments", response.structured_content[:code]
    assert_equal "clear_custom_subdomain", response.structured_content[:field]
  end

  test "folder_id and clear_folder together is a conflict" do
    paste = create_paste_for(@alice)
    folder = @alice.folders.create!(name: "Target")

    response = configure(token: paste.token, folder_id: folder.id, clear_folder: true)

    assert response.error?
    assert_equal "conflicting_arguments", response.structured_content[:code]
    assert_equal "clear_folder", response.structured_content[:field]
  end

  test "an invalid custom_subdomain returns the error contract with the field" do
    paste = create_paste_for(@alice)

    response = configure(token: paste.token, custom_subdomain: "bad_sub")

    assert response.error?
    assert_equal "validation_failed", response.structured_content[:code]
    assert_equal "custom_subdomain", response.structured_content[:field]
  end

  test "annotations mark it destructive, idempotent, non-read-only, closed-world" do
    annotations = McpTools::ConfigurePaste.annotations_value

    assert_equal false, annotations.read_only_hint
    assert_equal true, annotations.destructive_hint
    assert_equal true, annotations.idempotent_hint
    assert_equal false, annotations.open_world_hint
  end

  private
    def configure(**args)
      McpTools::ConfigurePaste.call(**args, server_context: @ctx)
    end

    def create_paste_for(user, content: "<p>x</p>", **options)
      paste = Paste.new(content: content, original_filename: "paste.html", user: user)
      options.each { |key, value| paste.public_send("#{key}=", value) }
      paste.save!
      paste
    end
end
