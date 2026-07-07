require "test_helper"

class AccountPastesTest < ActionDispatch::IntegrationTest
  test "users can sign up and land in their dashboard" do
    assert_difference "User.count" do
      post users_url, params: {
        user: {
          email_address: "New.User@example.com",
          password: "correct horse battery staple",
          password_confirmation: "correct horse battery staple"
        }
      }
    end

    assert_redirected_to pastes_url
    assert_equal "new.user@example.com", User.order(:created_at).last.email_address
  end

  test "sign in returns users to the protected get page they requested" do
    get api_keys_url
    assert_redirected_to new_session_url

    post session_url, params: { email_address: users(:alice).email_address, password: "password" }

    assert_redirected_to api_keys_url
  end

  test "head requests do not become sign in return paths" do
    head api_keys_url
    assert_redirected_to new_session_url

    post session_url, params: { email_address: users(:alice).email_address, password: "password" }

    assert_redirected_to pastes_url
  end

  test "signed in users see paste options on the upload page" do
    sign_in_as users(:alice)

    get root_url

    assert_response :success
    assert_select "input[name=custom_subdomain]"
    assert_select "input[name=password]"
    assert_select "select[name=folder_id]"
    assert_select "button[type=submit]"
  end

  test "signed in users can publish into a folder with a custom subdomain" do
    sign_in_as users(:alice)

    assert_difference "Paste.count" do
      post pastes_url, params: {
        file: fixture_file_upload("hello.html", "text/html"),
        custom_subdomain: "Launch-Plan",
        folder_id: folders(:projects).id
      }
    end

    paste = Paste.order(:created_at).last
    assert_redirected_to paste_url(paste)
    assert_equal users(:alice), paste.user
    assert_equal folders(:projects), paste.folder
    assert_equal "launch-plan", paste.custom_subdomain

    get "http://launch-plan.example.com/"
    assert_response :success
    assert_equal paste.content, response.body
  end

  test "password protected pastes require the password before rendering" do
    paste = Paste.create!(content: "<h1>Locked</h1>", original_filename: "locked.html", password: "sekret")

    get paste_url(paste)
    assert_redirected_to paste_password_url(paste)

    post paste_password_url(paste), params: { password: "wrong" }
    assert_response :unprocessable_entity

    post paste_password_url(paste), params: { password: "sekret" }
    assert_redirected_to paste_url(paste)

    follow_redirect!
    assert_response :success
    assert_select "iframe[src^=?]", "http://#{paste.token}.example.com/?paste_access_token="

    preview_url = css_select("iframe").first["src"]
    get preview_url
    assert_response :success
    assert_equal paste.content, response.body
  end

  test "password preview tokens stop working after a paste update" do
    paste = Paste.create!(content: "<h1>Locked</h1>", original_filename: "locked.html", password: "sekret")

    post paste_password_url(paste), params: { password: "sekret" }
    follow_redirect!
    preview_url = css_select("iframe").first["src"]

    paste.update!(content: "<h1>Changed</h1>")
    get preview_url

    assert_response :unauthorized
    assert_not_includes response.body, "Changed"
  end

  test "password session unlocks stop working after a paste update" do
    paste = Paste.create!(content: "<h1>Locked</h1>", original_filename: "locked.html", password: "sekret")

    post paste_password_url(paste), params: { password: "sekret" }
    assert_redirected_to paste_url(paste)

    get paste_url(paste)
    assert_response :success

    paste.update!(content: "<h1>Changed</h1>")

    get paste_url(paste)
    assert_redirected_to paste_password_url(paste)
  end

  test "signed in owners can re-upload the paste file without changing the token" do
    sign_in_as users(:alice)
    paste = Paste.create!(content: "<title>Before</title><p>v1</p>", original_filename: "before.html", user: users(:alice))

    get edit_owned_paste_url(paste)

    assert_response :success
    assert_select "input[type=file][accept*='.md'][accept*='.markdown']"

    patch owned_paste_url(paste), params: {
      file: fixture_file_upload("hello.html", "text/html"),
      custom_subdomain: "updated-page"
    }

    assert_redirected_to paste_url(paste)
    paste.reload
    assert_equal "hello.html", paste.original_filename
    assert_equal "Hello", paste.title
    assert_equal "updated-page", paste.custom_subdomain
    assert_includes paste.content, "Hello from a fixture"
  end

  test "show views are recorded" do
    paste = pastes(:snippet)

    assert_difference -> { paste.reload.views_count }, 1 do
      get paste_url(paste)
    end

    assert_equal "show", PasteView.order(:created_at).last.source
  end


  test "signed in users can create and revoke account api keys" do
    sign_in_as users(:alice)

    get api_keys_url
    assert_response :success

    assert_difference -> { ApiKey.active.where(user: users(:alice)).count } do
      post api_keys_url, params: { api_key: { name: "Agent", folder_id: folders(:projects).id } }
    end

    assert_response :created
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_select "meta[name='turbo-cache-control'][content='no-cache']"
    api_key = ApiKey.where(user: users(:alice)).order(:created_at).last
    assert_equal folders(:projects), api_key.folder
    assert_includes response.body, api_key.key_prefix
    assert_includes response.body, "pht_"

    assert_no_difference "ApiKey.count" do
      delete api_key_url(api_key)
    end

    assert_redirected_to api_keys_url
    assert_predicate api_key.reload, :revoked?
  end

  test "a signed in user cannot edit or update another user's paste" do
    paste = Paste.create!(content: "<title>Alice</title>", original_filename: "alice.html",
      user: users(:alice), custom_subdomain: "alice-doc")
    sign_in_as users(:bob)

    get edit_owned_paste_url(paste)
    assert_redirected_to paste_url(paste)
    assert_equal I18n.t("pastes.not_owner"), flash[:alert]

    patch owned_paste_url(paste), params: { custom_subdomain: "bob-took-it" }
    assert_redirected_to paste_url(paste)
    assert_equal I18n.t("pastes.not_owner"), flash[:alert]

    paste.reload
    assert_equal "alice-doc", paste.custom_subdomain
    assert_includes paste.content, "Alice"
  end

  test "a signed in user cannot revoke another user's api key" do
    sign_in_as users(:alice)

    assert_no_difference -> { ApiKey.active.count } do
      delete api_key_url(api_keys(:bob_key))
    end

    assert_response :not_found
    assert_predicate api_keys(:bob_key).reload, :active?
  end

  test "password protected pastes gate the raw, render, and markdown endpoints too" do
    paste = Paste.create!(content: "<h1>Top secret</h1>", original_filename: "locked.html", password: "sekret")

    [ raw_paste_url(paste), render_paste_url(paste), markdown_paste_url(paste) ].each do |url|
      get url
      assert_response :redirect
      assert_not_includes response.body, "Top secret"
    end

    post paste_password_url(paste), params: { password: "sekret" }
    get raw_paste_url(paste)
    assert_response :success
    assert_includes response.body, "Top secret"
  end

  test "the header nav marks the current section with aria-current" do
    sign_in_as users(:alice)

    get pastes_url
    assert_select "header a[aria-current=?]", "page", count: 1
    assert_select "header a[aria-current=?][href=?]", "page", pastes_path

    get api_keys_url
    assert_select "header a[aria-current=?][href=?]", "page", api_keys_path
  end

  test "guests auto-publish on file select, signed-in users load the file to set options first" do
    get root_url
    assert_select "form[data-dropzone-auto-submit-value=?]", "true"

    sign_in_as users(:alice)
    get root_url
    assert_select "form[data-dropzone-auto-submit-value=?]", "false"
  end

  test "the public paste inspector hides the owner's folder name from non-owners" do
    folder = users(:alice).folders.create!(name: "Confidential Client Q4")
    paste = Paste.create!(content: "<title>Filed</title><h1>Hi</h1>", original_filename: "f.html",
      user: users(:alice), folder: folder)

    get paste_url(paste) # anonymous public viewer
    assert_response :success
    assert_not_includes response.body, "Confidential Client Q4"

    sign_in_as users(:alice) # the owner sees it
    get paste_url(paste)
    assert_response :success
    assert_includes response.body, "Confidential Client Q4"
  end

  private
    def sign_in_as(user)
      post session_url, params: { email_address: user.email_address, password: "password" }
      assert_redirected_to pastes_url
    end
end
