require "test_helper"

# Authentication#request_authentication stores the requested path in the cookie
# session for post-login resume. The OAuth authorize endpoint naturally produces
# very long paths (a multi-kilobyte `state`), which would overflow the ~4 KB
# cookie session and raise CookieOverflow -- an uncaught 500 on the sign-in
# redirect. The path is stored only when it fits.
class AuthenticationReturnToTest < ActionDispatch::IntegrationTest
  test "a signed-out request to an authenticated route with a huge query does not 500" do
    huge_state = "s" * 5_000

    get "/oauth/authorized_applications", params: { state: huge_state }

    # Redirected to sign-in (not crashed): the over-long return path was simply
    # not stored, so the session cookie never overflowed.
    assert_response :see_other
    assert_redirected_to new_session_path
  end

  test "a normal-length path is still stored for post-login resume" do
    get "/oauth/authorized_applications"

    assert_response :see_other
    assert_equal "/oauth/authorized_applications", session[:return_to_after_authenticating]
  end

  test "an over-long path is skipped rather than stored" do
    get "/oauth/authorized_applications", params: { state: "s" * 5_000 }

    assert_nil session[:return_to_after_authenticating]
  end
end
