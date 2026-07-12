require "test_helper"

# RFC 8707 resource-indicator enforcement. Doorkeeper has no native support,
# so this is hand-rolled: both OAuth endpoints require EXACTLY ONE `resource`
# parameter matching McpOauth::CONFIG[:resource_uri] (scheme/host
# case-insensitive, path byte-exact), and always persist the CANONICAL
# spelling on grants and tokens so the /mcp audience check can compare
# exactly. Repeats are checked on the raw query/body because Rails params
# collapse `resource=a&resource=b` into the last value.
class OauthResourceIndicatorTest < ActionDispatch::IntegrationTest
  CODE_VERIFIER = "wXyVZ0m3basmgTt5c8sJVzXvUqAHQu7hMYJhZpJp4NM-example-verifier"
  CANONICAL_RESOURCE = McpOauth::CONFIG[:resource_uri]
  UPPERCASED_RESOURCE = begin
    uri = URI.parse(CANONICAL_RESOURCE)
    "#{uri.scheme.upcase}://#{uri.host.upcase}#{uri.path}"
  end

  # --- Authorization endpoint -----------------------------------------------

  test "authorize without a resource parameter is rejected with invalid_target" do
    sign_in_as users(:alice)

    get "/oauth/authorize", params: authorize_params(resource: nil)
    assert_invalid_target_page
  end

  test "authorize with a repeated resource parameter is rejected" do
    sign_in_as users(:alice)

    # Hand-built query string: Rails params would collapse the repeat, so the
    # implementation must inspect the raw query to catch it.
    query = authorize_params.to_query + "&resource=#{CGI.escape(CANONICAL_RESOURCE)}"
    get "/oauth/authorize?#{query}"
    assert_invalid_target_page
  end

  test "authorize with an array resource parameter is rejected" do
    sign_in_as users(:alice)

    get "/oauth/authorize?#{authorize_params(resource: nil).to_query}&resource[]=#{CGI.escape(CANONICAL_RESOURCE)}"
    assert_invalid_target_page
  end

  test "authorize with a path-cased resource variant is rejected" do
    sign_in_as users(:alice)

    # Scheme and host compare case-insensitively but the path is byte-exact
    # (RFC 3986): /MCP is a different resource than /mcp.
    get "/oauth/authorize", params: authorize_params(resource: CANONICAL_RESOURCE.sub("/mcp", "/MCP"))
    assert_invalid_target_page
  end

  test "authorize with a foreign resource is rejected" do
    sign_in_as users(:alice)

    get "/oauth/authorize", params: authorize_params(resource: "https://evil.example.com/mcp")
    assert_invalid_target_page
  end

  test "approving consent without a resource creates no grant" do
    sign_in_as users(:alice)

    assert_no_difference "Doorkeeper::AccessGrant.count" do
      post "/oauth/authorize", params: authorize_params(resource: nil)
    end
    assert_invalid_target_page
  end

  test "an uppercase scheme and host variant is accepted and stored canonically" do
    sign_in_as users(:alice)

    get "/oauth/authorize", params: authorize_params(resource: UPPERCASED_RESOURCE)
    assert_response :success

    # The consent form must already carry the CANONICAL spelling -- never the
    # client's -- so the approve POST persists the normalized value.
    assert_select "form input[type=hidden][name=resource][value=?]", CANONICAL_RESOURCE

    post "/oauth/authorize", params: authorize_params(resource: UPPERCASED_RESOURCE)
    assert_response :redirect

    grant = Doorkeeper::AccessGrant.order(:id).last
    assert_equal CANONICAL_RESOURCE, grant.resource
  end

  # --- Token endpoint --------------------------------------------------------

  test "token exchange without a resource parameter is rejected with invalid_target" do
    code = obtain_authorization_code

    assert_no_difference "Doorkeeper::AccessToken.count" do
      post "/oauth/token", params: token_params(code: code, resource: nil)
    end

    assert_response :bad_request
    assert_equal "invalid_target", response.parsed_body["error"]
  end

  test "token exchange with a repeated resource parameter is rejected" do
    code = obtain_authorization_code

    body = token_params(code: code).to_query + "&resource=#{CGI.escape(CANONICAL_RESOURCE)}"
    post "/oauth/token", params: body,
      headers: { "Content-Type" => "application/x-www-form-urlencoded" }

    assert_response :bad_request
    assert_equal "invalid_target", response.parsed_body["error"]
  end

  test "token exchange with a mismatched resource is rejected" do
    code = obtain_authorization_code

    post "/oauth/token", params: token_params(code: code, resource: "#{CANONICAL_RESOURCE}/other")
    assert_response :bad_request
    assert_equal "invalid_target", response.parsed_body["error"]
  end

  test "uppercase resource spelling at both endpoints still yields a canonical token" do
    code = obtain_authorization_code(resource: UPPERCASED_RESOURCE)

    post "/oauth/token", params: token_params(code: code, resource: UPPERCASED_RESOURCE)
    assert_response :success

    token = Doorkeeper::AccessToken.order(:id).last
    assert_equal CANONICAL_RESOURCE, token.resource
  end

  test "an uppercase-equivalent resource end-to-end mints a token usable at /mcp" do
    # Round-7 proof that canonical storage composes with the /mcp audience
    # check: the whole authorize+token dance runs through the client's
    # uppercase spelling, and the resulting token -- stored canonically --
    # must still authenticate, not merely persist correctly (the other tests
    # in this file stop at grant/token storage assertions).
    code = obtain_authorization_code(resource: UPPERCASED_RESOURCE)

    post "/oauth/token", params: token_params(code: code, resource: UPPERCASED_RESOURCE)
    assert_response :success
    access_token = response.parsed_body["access_token"]

    post "/mcp", params: {
      jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1.0" } }
    }.to_json,
      headers: {
        "Content-Type" => "application/json",
        "Accept" => "application/json, text/event-stream",
        "Authorization" => "Bearer #{access_token}"
      }

    assert_response :ok
    assert response.parsed_body["result"].present?
  end

  test "refresh without a resource parameter inherits the original resource" do
    refresh_token = exchange_code_for_token["refresh_token"]

    post "/oauth/token", params: refresh_params(refresh_token).except(:resource)
    assert_response :success

    refreshed = Doorkeeper::AccessToken.by_token(response.parsed_body["access_token"])
    assert_equal CANONICAL_RESOURCE, refreshed.resource
  end

  test "refresh with a mismatched resource is rejected" do
    refresh_token = exchange_code_for_token["refresh_token"]

    post "/oauth/token", params: refresh_params(refresh_token).merge(resource: "#{CANONICAL_RESOURCE}/other")
    assert_response :bad_request
    assert_equal "invalid_target", response.parsed_body["error"]
  end

  test "refresh with a repeated resource is rejected" do
    refresh_token = exchange_code_for_token["refresh_token"]
    body = refresh_params(refresh_token).to_query + "&resource=#{CGI.escape(CANONICAL_RESOURCE)}"

    post "/oauth/token", params: body,
      headers: { "Content-Type" => "application/x-www-form-urlencoded" }
    assert_response :bad_request
    assert_equal "invalid_target", response.parsed_body["error"]
  end

  test "refresh with an array resource is rejected" do
    refresh_token = exchange_code_for_token["refresh_token"]
    body = refresh_params(refresh_token).except(:resource).to_query +
      "&resource[]=#{CGI.escape(CANONICAL_RESOURCE)}"

    post "/oauth/token", params: body,
      headers: { "Content-Type" => "application/x-www-form-urlencoded" }
    assert_response :bad_request
    assert_equal "invalid_target", response.parsed_body["error"]
  end

  test "a refreshed token keeps the canonical resource" do
    refresh_token = exchange_code_for_token["refresh_token"]

    post "/oauth/token", params: refresh_params(refresh_token)
    assert_response :success

    refreshed = Doorkeeper::AccessToken.by_token(response.parsed_body["access_token"])
    assert_equal CANONICAL_RESOURCE, refreshed.resource
  end

  private
    def sign_in_as(user)
      post session_url, params: { email_address: user.email_address, password: "password" }
    end

    def code_challenge
      Base64.urlsafe_encode64(Digest::SHA256.digest(CODE_VERIFIER), padding: false)
    end

    def authorize_params(**overrides)
      {
        client_id: oauth_applications(:mcp_client).uid,
        redirect_uri: oauth_applications(:mcp_client).redirect_uri,
        response_type: "code",
        scope: "mcp:read mcp:write",
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

    def obtain_authorization_code(**overrides)
      sign_in_as users(:alice)
      post "/oauth/authorize", params: authorize_params(**overrides)
      assert_response :redirect

      query = Rack::Utils.parse_query(URI.parse(response.location).query)
      assert query["code"].present?, "expected an authorization code in #{response.location}"
      query["code"]
    end

    def exchange_code_for_token
      post "/oauth/token", params: token_params(code: obtain_authorization_code)
      assert_response :success
      response.parsed_body
    end

    def assert_invalid_target_page
      assert_response :bad_request
      assert_includes response.body, I18n.t("doorkeeper.errors.messages.invalid_target")
    end
end
