require "test_helper"

class FoldersControllerTest < ActionDispatch::IntegrationTest
  test "folder pages require authentication" do
    [
      -> { get folders_url },
      -> { get folder_url(folders(:projects)) },
      -> { get new_folder_url },
      -> { get edit_folder_url(folders(:projects)) }
    ].each do |request|
      request.call
      assert_redirected_to new_session_url
    end

    assert_no_difference "Folder.count" do
      post folders_url, params: { folder: { name: "Anon" } }
    end
    assert_redirected_to new_session_url

    # Non-GET auth redirects must be 303 so Turbo follows to sign-in as a GET
    # instead of replaying PATCH/DELETE against the GET-only /session/new.
    patch folder_url(folders(:projects)), params: { folder: { name: "Nope" } }
    assert_response :see_other
    assert_redirected_to new_session_url
    assert_equal "Projects", folders(:projects).reload.name

    assert_no_difference "Folder.count" do
      delete folder_url(folders(:projects))
    end
    assert_response :see_other
    assert_redirected_to new_session_url
  end

  test "a signed in user cannot view, edit, update, or destroy another user's folder" do
    sign_in_as users(:bob)
    alice_folder = folders(:projects)

    get folder_url(alice_folder)
    assert_response :not_found

    get edit_folder_url(alice_folder)
    assert_response :not_found

    patch folder_url(alice_folder), params: { folder: { name: "Hijacked" } }
    assert_response :not_found
    assert_equal "Projects", alice_folder.reload.name

    assert_no_difference "Folder.count" do
      delete folder_url(alice_folder)
    end
    assert_response :not_found
  end

  test "owners can view a folder's pastes without error" do
    sign_in_as users(:alice)
    Paste.create!(content: "<title>In Projects</title>", original_filename: "p.html",
      user: users(:alice), folder: folders(:projects))

    get folder_url(folders(:projects))

    assert_response :success
    assert_includes response.body, "In Projects"
  end

  test "owners manage their own folders" do
    sign_in_as users(:alice)

    assert_difference -> { users(:alice).folders.count }, 1 do
      post folders_url, params: { folder: { name: "Drafts" } }
    end
    folder = users(:alice).folders.find_by!(name: "Drafts")
    assert_redirected_to folder_url(folder)

    patch folder_url(folder), params: { folder: { name: "Published" } }
    assert_redirected_to folder_url(folder)
    assert_equal "Published", folder.reload.name

    assert_difference -> { users(:alice).folders.count }, -1 do
      delete folder_url(folder)
    end
    assert_redirected_to pastes_url
  end

  private
    def sign_in_as(user)
      post session_url, params: { email_address: user.email_address, password: "password" }
      assert_redirected_to pastes_url
    end
end
