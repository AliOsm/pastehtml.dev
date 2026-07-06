require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  test "sign in with valid credentials creates a session and redirects to the dashboard" do
    assert_difference "Session.count", 1 do
      post session_url, params: { email_address: users(:alice).email_address, password: "password" }
    end

    assert_redirected_to pastes_url
  end

  test "sign in with a wrong password is rejected and starts no session" do
    assert_no_difference "Session.count" do
      post session_url, params: { email_address: users(:alice).email_address, password: "wrong-password" }
    end

    assert_redirected_to new_session_path(email_address: users(:alice).email_address)
    assert_equal I18n.t("sessions.invalid"), flash[:alert]

    # The failed attempt must not have established a resumable session.
    get api_keys_url
    assert_redirected_to new_session_url
  end

  test "sign in with an unknown email is rejected and starts no session" do
    assert_no_difference "Session.count" do
      post session_url, params: { email_address: "nobody@example.com", password: "whatever" }
    end

    assert_redirected_to new_session_path(email_address: "nobody@example.com")
    assert_equal I18n.t("sessions.invalid"), flash[:alert]
  end

  test "sign out destroys the session, returns 303, and stops resuming the session" do
    post session_url, params: { email_address: users(:alice).email_address, password: "password" }
    assert_redirected_to pastes_url

    assert_difference "Session.count", -1 do
      delete session_url
    end

    # 303 See Other so Turbo re-issues the follow-up as a GET (a 302 would make
    # the browser re-send DELETE to the GET-only root path).
    assert_response :see_other
    assert_redirected_to root_path

    get api_keys_url
    assert_redirected_to new_session_url
  end

  test "signing in resets the session, dropping pre-authentication data" do
    # Seed a value into the pre-auth session via the paste-password unlock flow.
    paste = Paste.create!(content: "<h1>Locked</h1>", original_filename: "locked.html", password: "sekret")
    post paste_password_url(paste), params: { password: "sekret" }
    get paste_url(paste)
    assert_response :success # unlocked in the current session

    post session_url, params: { email_address: users(:alice).email_address, password: "password" }
    assert_redirected_to pastes_url

    # reset_session dropped the pre-auth unlock, so the paste is locked again.
    get paste_url(paste)
    assert_redirected_to paste_password_url(paste)
  end
end
