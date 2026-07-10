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

  # The return-to cap and the DCR redirect_uri cap are aligned: an authorize path
  # built from the LONGEST redirect_uri registration accepts, plus a normal
  # state, still fits and resumes -- so no client accepted at registration is
  # left unable to authenticate.
  test "a max-length accepted redirect_uri still yields a resumable authorize path" do
    max_uri_length = Oauth::RegistrationsController::MAX_REDIRECT_URI_LENGTH
    prefix = "https://client.example.com/"
    redirect_uri = prefix + ("a" * (max_uri_length - prefix.length))
    assert_equal max_uri_length, redirect_uri.length, "sanity: exactly the max accepted redirect_uri"

    get "/oauth/authorize", params: {
      client_id: "c" * 43, redirect_uri: redirect_uri, response_type: "code",
      scope: "mcp:read mcp:write", state: "s" * 128,
      code_challenge: "d" * 43, code_challenge_method: "S256",
      resource: McpOauth::CONFIG[:resource_uri]
    }

    assert_response :see_other
    stored = session[:return_to_after_authenticating]
    assert_not_nil stored, "a max-redirect-uri authorize path must fit and resume"
    assert_operator stored.bytesize, :<=, Authentication::MAX_RETURN_TO_BYTES
  end
end
