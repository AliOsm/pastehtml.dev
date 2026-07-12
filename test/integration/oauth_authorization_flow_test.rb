require "test_helper"

# The Doorkeeper authorization-code + PKCE flow that MCP clients (Claude Code,
# Codex CLI, ...) drive: consent screen, code exchange, refresh rotation, and
# the token-hardening decisions (hashed secrets, header-only bearer tokens).
class OauthAuthorizationFlowTest < ActionDispatch::IntegrationTest
  CODE_VERIFIER = "wXyVZ0m3basmgTt5c8sJVzXvUqAHQu7hMYJhZpJp4NM-example-verifier"
  CANONICAL_RESOURCE = McpOauth::CONFIG[:resource_uri]

  test "signed-in user completes the full authorization-code + PKCE flow" do
    sign_in_as users(:alice)
    client = oauth_applications(:mcp_client)

    get "/oauth/authorize", params: authorize_params
    assert_response :success

    # The consent form must round-trip the RFC 8707 resource indicator: the
    # approve POST is a fresh request and the grant is minted from its params.
    assert_select "form input[type=hidden][name=resource][value=?]", CANONICAL_RESOURCE
    assert_select "input[type=hidden][name=code_challenge][value=?]", code_challenge
    assert_includes response.body, client.name

    # Approval and denial redirect to a client-controlled callback origin
    # (usually localhost for CLI agents). Turbo must not turn those redirects
    # into cross-origin fetches; both forms require native browser navigation.
    assert_select "form[data-turbo='false']", count: 2

    # Requested scopes are shown with human labels.
    assert_includes response.body, I18n.t("doorkeeper.scopes.mcp:read")
    assert_includes response.body, I18n.t("doorkeeper.scopes.mcp:pastes:write")
    assert_includes response.body, I18n.t("doorkeeper.scopes.mcp:folders:write")

    code = approve_authorization!
    grant = Doorkeeper::AccessGrant.order(:id).last
    assert_equal CANONICAL_RESOURCE, grant.resource
    assert_equal "S256", grant.code_challenge_method

    post "/oauth/token", params: token_params(code: code)
    assert_response :success

    body = response.parsed_body
    assert body["access_token"].present?
    assert body["refresh_token"].present?
    assert_equal "Bearer", body["token_type"]
    assert_equal 1.hour.to_i, body["expires_in"]
    assert_equal "mcp:read mcp:pastes:write mcp:folders:write", body["scope"]

    token = Doorkeeper::AccessToken.order(:id).last
    assert_equal CANONICAL_RESOURCE, token.resource
    assert_equal users(:alice).id, token.resource_owner_id
  end

  test "unauthenticated authorize request resumes the full OAuth URL after sign-in" do
    authorize_url = "/oauth/authorize?#{authorize_params.to_query}"

    get authorize_url
    assert_response :see_other
    assert_redirected_to new_session_path

    # SessionsController#create resumes ONLY via
    # session[:return_to_after_authenticating] -- this must land back on the
    # exact authorize URL, query string included, or the OAuth flow dies.
    post session_url, params: { email_address: users(:alice).email_address, password: "password" }
    assert_response :see_other
    assert_equal authorize_url, URI.parse(response.location).then { |u| "#{u.path}?#{u.query}" }

    follow_redirect!
    assert_response :success
    assert_select "form input[type=hidden][name=resource][value=?]", CANONICAL_RESOURCE
  end

  test "new user signing up during authorization resumes the full OAuth URL" do
    authorize_url = "/oauth/authorize?#{authorize_params.to_query}"

    get authorize_url
    assert_response :see_other
    assert_redirected_to new_session_path

    # Follow the sign-up link without losing the server-side OAuth return path.
    get new_user_path
    assert_response :success

    assert_difference "User.count", 1 do
      post users_url, params: {
        user: {
          email_address: "new-mcp-user@example.com",
          password: "correct horse battery staple",
          password_confirmation: "correct horse battery staple"
        }
      }
    end

    assert_response :see_other
    assert_equal authorize_url, URI.parse(response.location).then { |u| "#{u.path}?#{u.query}" }
    assert_nil session[:return_to_after_authenticating]

    follow_redirect!
    assert_response :success
    assert_select "form input[type=hidden][name=resource][value=?]", CANONICAL_RESOURCE
  end

  test "dynamically registered clients are labeled unverified with their redirect host" do
    sign_in_as users(:alice)
    client = oauth_applications(:dynamic_client)

    get "/oauth/authorize", params: authorize_params(client_id: client.uid, redirect_uri: client.redirect_uri)
    assert_response :success

    # Anyone can register client_name: "Codex" via DCR -- the consent screen
    # must lead with "unverified" plus the verifiable redirect host, never
    # just the self-asserted name.
    assert_includes response.body, I18n.t("doorkeeper.authorizations.new.unverified_client")
    assert_includes response.body, "localhost"
  end

  test "authorize request without a PKCE code challenge is rejected" do
    sign_in_as users(:alice)

    get "/oauth/authorize", params: authorize_params(code_challenge: nil, code_challenge_method: nil)
    assert_response :bad_request
    assert_includes response.body, I18n.t("doorkeeper.errors.messages.invalid_request.invalid_code_challenge")
  end

  test "authorize request with the plain PKCE method is rejected" do
    sign_in_as users(:alice)

    get "/oauth/authorize", params: authorize_params(code_challenge: CODE_VERIFIER, code_challenge_method: "plain")
    assert_response :bad_request
    assert_includes response.body,
      I18n.t("doorkeeper.errors.messages.invalid_code_challenge_method", challenge_methods: "S256", count: 1)
  end

  test "token exchange without the code verifier is rejected" do
    code = obtain_authorization_code

    post "/oauth/token", params: token_params(code: code).except(:code_verifier)
    assert_response :bad_request
    assert_equal "invalid_request", response.parsed_body["error"]
  end

  test "token exchange with a wrong code verifier is rejected" do
    code = obtain_authorization_code

    post "/oauth/token", params: token_params(code: code, code_verifier: "not-the-right-verifier-but-long-enough")
    assert_response :bad_request
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "refresh rotates the token pair and the old refresh token dies immediately" do
    first = exchange_code_for_token

    post "/oauth/token", params: refresh_params(first["refresh_token"])
    assert_response :success

    second = response.parsed_body
    assert second["access_token"].present?
    assert second["refresh_token"].present?
    assert_not_equal first["access_token"], second["access_token"]
    assert_not_equal first["refresh_token"], second["refresh_token"]

    # No previous_refresh_token column => no grace window: replaying the
    # rotated-out refresh token must fail outright.
    post "/oauth/token", params: refresh_params(first["refresh_token"])
    assert_response :bad_request
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "access and refresh tokens are stored hashed, not in plaintext" do
    body = exchange_code_for_token
    token = Doorkeeper::AccessToken.order(:id).last

    assert_not_equal body["access_token"], token.token
    assert_not_equal body["refresh_token"], token.refresh_token

    # The plaintext still authenticates through the hashed lookup.
    assert_equal token, Doorkeeper::AccessToken.by_token(body["access_token"])
  end

  test "bearer tokens are only accepted from the Authorization header, never request params" do
    plaintext = exchange_code_for_token["access_token"]

    from_header = Doorkeeper::OAuth::Token.from_request(
      request_with("HTTP_AUTHORIZATION" => "Bearer #{plaintext}"),
      *Doorkeeper.config.access_token_methods
    )
    assert_equal plaintext, from_header

    from_param = Doorkeeper::OAuth::Token.from_request(
      request_with(params: { access_token: plaintext, bearer_token: plaintext }),
      *Doorkeeper.config.access_token_methods
    )
    assert_nil from_param
  end

  test "the retired mcp:write spelling is an invalid_scope error, never a grant" do
    sign_in_as users(:alice)

    post "/oauth/authorize", params: authorize_params(scope: "mcp:read mcp:write")

    # Doorkeeper hands redirectable errors back to the client callback.
    assert_response :redirect
    assert_includes response.location, "error=invalid_scope"
    assert_nil Doorkeeper::AccessGrant.order(:id).last
  end

  test "omitting scope grants the default mcp:read scope" do
    sign_in_as users(:alice)

    post "/oauth/authorize", params: authorize_params.except(:scope)
    assert_response :redirect

    assert_equal "mcp:read", Doorkeeper::AccessGrant.order(:id).last.scopes.to_s
  end

  private
    def sign_in_as(user)
      post session_url, params: { email_address: user.email_address, password: "password" }
    end

    def code_challenge(verifier = CODE_VERIFIER)
      Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    end

    def authorize_params(**overrides)
      {
        client_id: oauth_applications(:mcp_client).uid,
        redirect_uri: oauth_applications(:mcp_client).redirect_uri,
        response_type: "code",
        scope: "mcp:read mcp:pastes:write mcp:folders:write",
        state: "opaque-client-state",
        code_challenge: code_challenge,
        code_challenge_method: "S256",
        resource: CANONICAL_RESOURCE
      }.merge(overrides).compact
    end

    def token_params(code:, **overrides)
      {
        grant_type: "authorization_code",
        client_id: oauth_applications(:mcp_client).uid,
        redirect_uri: oauth_applications(:mcp_client).redirect_uri,
        code: code,
        code_verifier: CODE_VERIFIER,
        resource: CANONICAL_RESOURCE
      }.merge(overrides).compact
    end

    def refresh_params(refresh_token)
      {
        grant_type: "refresh_token",
        client_id: oauth_applications(:mcp_client).uid,
        refresh_token: refresh_token,
        resource: CANONICAL_RESOURCE
      }
    end

    def approve_authorization!(**overrides)
      post "/oauth/authorize", params: authorize_params(**overrides)
      assert_response :redirect

      location = URI.parse(response.location)
      assert_equal "/callback", location.path
      query = Rack::Utils.parse_query(location.query)
      assert_equal "opaque-client-state", query["state"]
      assert query["code"].present?, "expected an authorization code in #{response.location}"
      query["code"]
    end

    def obtain_authorization_code
      sign_in_as users(:alice)
      approve_authorization!
    end

    def exchange_code_for_token
      post "/oauth/token", params: token_params(code: obtain_authorization_code)
      assert_response :success
      response.parsed_body
    end

    def request_with(params: nil, **env)
      ActionDispatch::Request.new({
        "REQUEST_METHOD" => "GET",
        "PATH_INFO" => "/mcp",
        "QUERY_STRING" => params ? params.to_query : "",
        "rack.input" => StringIO.new(+"")
      }.merge(env))
    end
end
