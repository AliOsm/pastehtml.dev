require "test_helper"

# The §9 end-to-end integration sweep: cross-cutting scenarios that no single
# component test owns. Where the other OAuth/MCP test files each drive one
# layer (discovery, DCR, the authorization-code flow, the /mcp transport,
# tool wiring) against fixtures or a single hop, this file simulates what a
# real client (Claude Code, Codex CLI) actually does end-to-end: discover,
# self-register, authorize, exchange, call a tool, and refresh -- each step
# feeding the next, starting from nothing but a signed-in user.
class McpAgentJourneyTest < ActionDispatch::IntegrationTest
  CANONICAL_RESOURCE = McpOauth::CONFIG[:resource_uri]

  test "a coding agent discovers, registers, authorizes, calls a tool, and refreshes" do
    # --- a. Cold POST /mcp with no token -------------------------------------
    post "/mcp", params: initialize_body, headers: mcp_headers
    assert_response :unauthorized

    challenge = response.headers["WWW-Authenticate"]
    assert_not_includes challenge, "error="
    resource_metadata_url = challenge[/resource_metadata="([^"]+)"/, 1]
    assert resource_metadata_url.present?, "expected a resource_metadata pointer in #{challenge}"

    # --- b. Follow it to the protected-resource metadata ---------------------
    get resource_metadata_url
    assert_response :success
    authorization_server = response.parsed_body["authorization_servers"]&.first
    assert authorization_server.present?

    # --- c. Discover the authorization server's endpoints --------------------
    get "#{authorization_server}/.well-known/oauth-authorization-server"
    assert_response :success
    as_metadata = response.parsed_body
    assert_equal [ "S256" ], as_metadata["code_challenge_methods_supported"]

    authorization_endpoint = as_metadata["authorization_endpoint"]
    token_endpoint = as_metadata["token_endpoint"]
    registration_endpoint = as_metadata["registration_endpoint"]

    # --- d. Dynamic Client Registration ---------------------------------------
    redirect_uri = "http://127.0.0.1:43217/callback"
    post registration_endpoint, params: { redirect_uris: [ redirect_uri ] }, as: :json
    assert_response :created

    registration = response.parsed_body
    client_id = registration["client_id"]
    assert client_id.present?
    assert_not registration.key?("client_secret"), "DCR must never hand back a client_secret"

    # --- e. Sign in, then authorize with PKCE (S256) --------------------------
    sign_in_as users(:alice)

    verifier = SecureRandom.urlsafe_base64(48)
    code_challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    state = "agent-state-#{SecureRandom.hex(4)}"

    authorize_params = {
      client_id: client_id,
      redirect_uri: redirect_uri,
      response_type: "code",
      scope: "mcp:read mcp:pastes:write mcp:folders:write",
      state: state,
      code_challenge: code_challenge,
      code_challenge_method: "S256",
      resource: CANONICAL_RESOURCE
    }

    get authorization_endpoint, params: authorize_params
    assert_response :success

    # Mimic the consent form's approve submission: re-POST the exact param set
    # the rendered hidden fields carry (see oauth_authorization_flow_test.rb).
    post authorization_endpoint, params: authorize_params
    assert_response :redirect

    location = URI.parse(response.location)
    assert_equal "/callback", location.path
    query = Rack::Utils.parse_query(location.query)
    assert_equal state, query["state"], "state must round-trip through the redirect"
    code = query["code"]
    assert code.present?

    # --- f. Exchange the code for a token pair --------------------------------
    post token_endpoint, params: {
      grant_type: "authorization_code",
      client_id: client_id,
      redirect_uri: redirect_uri,
      code: code,
      code_verifier: verifier,
      resource: CANONICAL_RESOURCE
    }
    assert_response :success

    tokens = response.parsed_body
    access_token = tokens["access_token"]
    refresh_token = tokens["refresh_token"]
    assert access_token.present?
    assert refresh_token.present?

    # --- g. initialize ---------------------------------------------------------
    post "/mcp", params: initialize_body, headers: mcp_headers(access_token)
    assert_response :ok
    assert response.parsed_body["result"].present?

    # --- h. tools/list, then tools/call create_paste ---------------------------
    post "/mcp", params: tools_list_body, headers: mcp_headers(access_token)
    assert_response :ok
    tool_names = response.parsed_body.dig("result", "tools").map { |tool| tool["name"] }
    assert_includes tool_names, "create_paste"

    post "/mcp",
      params: tools_call_body("create_paste", content: "<title>Agent Journey</title><p>hi</p>", format: "html"),
      headers: mcp_headers(access_token)
    assert_response :ok

    result = response.parsed_body["result"]
    assert_not result["isError"]
    paste_token = result.dig("structuredContent", "token")
    assert paste_token.present?

    paste = Paste.find_by(token: paste_token)
    assert paste.present?
    assert_equal users(:alice), paste.user

    # --- i. Refresh: rotates the pair, kills the old refresh token ------------
    post token_endpoint, params: {
      grant_type: "refresh_token",
      client_id: client_id,
      refresh_token: refresh_token,
      resource: CANONICAL_RESOURCE
    }
    assert_response :success

    refreshed = response.parsed_body
    new_access_token = refreshed["access_token"]
    new_refresh_token = refreshed["refresh_token"]
    assert_not_equal access_token, new_access_token
    assert_not_equal refresh_token, new_refresh_token

    # The rotated-out refresh token is immediately dead (no grace window).
    post token_endpoint, params: {
      grant_type: "refresh_token",
      client_id: client_id,
      refresh_token: refresh_token,
      resource: CANONICAL_RESOURCE
    }
    assert_response :bad_request
    assert_equal "invalid_grant", response.parsed_body["error"]

    # The new access token authenticates at /mcp.
    post "/mcp", params: initialize_body, headers: mcp_headers(new_access_token)
    assert_response :ok
  end

  # --- Paste-host isolation ---------------------------------------------------

  test "OAuth and MCP endpoints are unreachable from a paste-origin host" do
    # A 32-lowercase-alphanumeric label is a valid *paste token* subdomain
    # (Paste::TOKEN_LENGTH) -- here suffixed onto the app's own configured
    # host, proving the paste_host routing constraint (which wins before the
    # app-host constraint is ever consulted) shields these routes even from a
    # subdomain of the literal MCP host string.
    host! "#{"a" * 32}.www.example.com"

    get "/.well-known/oauth-authorization-server"
    assert_response :not_found

    post "/oauth/register", params: { redirect_uris: [ "http://127.0.0.1:1234/callback" ] }, as: :json
    assert_response :not_found

    post "/mcp", params: initialize_body, headers: mcp_headers
    assert_response :not_found

    get "/oauth/authorize", params: {
      client_id: "whatever",
      redirect_uri: "http://127.0.0.1:1/cb",
      response_type: "code",
      scope: "mcp:read",
      resource: CANONICAL_RESOURCE
    }
    assert_response :not_found
  end

  test "OAuth and MCP endpoints route-404 on a non-canonical host that is neither the app host nor a paste host" do
    # Genuinely missing §9 coverage (spec: "non-canonical Host -> routing 404
    # ... the transport's 403 is unreachable there -- it's defense-in-depth,
    # not the tested behavior"). This is distinct from paste-host isolation
    # above: McpOauth::CONFIG[:host] is "www.example.com" in test, and Rails'
    # `constraints host:` is an exact match, not a suffix match -- a bare
    # "example.com" is neither that host nor a paste-token/custom-subdomain
    # host (only two labels, no subdomain at all), so the apex-constrained
    # OAuth/MCP block in config/routes.rb simply has no route to offer it.
    host! "example.com"

    get "/.well-known/oauth-authorization-server"
    assert_response :not_found

    post "/oauth/register", params: { redirect_uris: [ "http://127.0.0.1:1234/callback" ] }, as: :json
    assert_response :not_found

    post "/mcp", params: initialize_body, headers: mcp_headers
    assert_response :not_found

    # Contrast: this isn't a blanket host failure -- ordinary, non-MCP app
    # routes still resolve on the same host, only the apex-constrained
    # OAuth/MCP surface does not.
    get "/"
    assert_response :success
  end

  # --- Token-in-param rejection -------------------------------------------------

  test "a token supplied only as a query parameter is rejected -- header-only bearer auth" do
    token = mint_token

    post "/mcp?access_token=#{token.plaintext_token}", params: initialize_body,
      headers: { "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream" }

    assert_response :unauthorized
    challenge = response.headers["WWW-Authenticate"]
    assert challenge.present?
    assert_not_includes challenge, "error=", "a token in a query param must not be picked up at all"
  end

  # --- Log filtering proof ------------------------------------------------------

  test "the token endpoint filters `code` and /mcp filters tool-call `content` out of request logs" do
    application = oauth_applications(:mcp_client)
    sign_in_as users(:alice)

    verifier = "wXyVZ0m3basmgTt5c8sJVzXvUqAHQu7hMYJhZpJp4NM-example-verifier"
    code_challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)

    post "/oauth/authorize", params: {
      client_id: application.uid,
      redirect_uri: application.redirect_uri,
      response_type: "code",
      scope: "mcp:read mcp:pastes:write mcp:folders:write",
      state: "log-filter-state",
      code_challenge: code_challenge,
      code_challenge_method: "S256",
      resource: CANONICAL_RESOURCE
    }
    assert_response :redirect
    code = Rack::Utils.parse_query(URI.parse(response.location).query)["code"]
    assert code.present?

    token_log = capture_controller_log do
      post "/oauth/token", params: {
        grant_type: "authorization_code",
        client_id: application.uid,
        redirect_uri: application.redirect_uri,
        code: code,
        code_verifier: verifier,
        resource: CANONICAL_RESOURCE
      }
    end
    assert_response :success
    access_token = response.parsed_body["access_token"]

    assert_includes token_log, "Parameters:"
    assert_includes token_log, ActiveSupport::ParameterFilter::FILTERED
    assert_not_includes token_log, code
    assert_not_includes token_log, verifier

    secret_marker = "SECRET-PASTE-BODY-#{SecureRandom.hex(6)}"
    mcp_log = capture_controller_log do
      post "/mcp",
        params: tools_call_body("create_paste", content: "<title>Log Filter</title><p>#{secret_marker}</p>", format: "html"),
        headers: mcp_headers(access_token)
    end
    assert_response :ok

    assert_includes mcp_log, "Parameters:"
    assert_includes mcp_log, ActiveSupport::ParameterFilter::FILTERED
    assert_not_includes mcp_log, secret_marker
  end

  private
    def sign_in_as(user)
      post session_url, params: { email_address: user.email_address, password: "password" }
    end

    def mint_token(user: users(:alice), application: oauth_applications(:mcp_client), scopes: "mcp:read mcp:pastes:write mcp:folders:write")
      Doorkeeper::AccessToken.create!(
        application: application,
        resource_owner_id: user.id,
        scopes: scopes,
        expires_in: 3600,
        resource: CANONICAL_RESOURCE
      )
    end

    def mcp_headers(token = nil)
      headers = { "Content-Type" => "application/json", "Accept" => "application/json, text/event-stream" }
      headers["Authorization"] = "Bearer #{token}" if token
      headers
    end

    def initialize_body
      {
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2025-11-25",
          capabilities: {},
          clientInfo: { name: "test-agent", version: "1.0" }
        }
      }.to_json
    end

    def tools_list_body
      { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }.to_json
    end

    def tools_call_body(name, **arguments)
      { jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: name, arguments: arguments } }.to_json
    end

    # Swaps the logger the "Processing by ... / Parameters: ..." request log
    # lines are written through. ActionController::LogSubscriber#logger is
    # hardcoded to `ActionController::Base.logger` -- not Rails.logger, and
    # not per-controller-class -- regardless of which ActionController::API
    # subclass actually handled the request (McpController, Oauth::TokensController,
    # ...), so that's the one seam that actually intercepts them. Safe under
    # the suite's process-forked parallelization (test_helper.rb parallelizes
    # by process, not threads): this only mutates state in the current worker
    # process, and the block form always restores the previous logger.
    def capture_controller_log
      buffer = StringIO.new
      previous_logger = ActionController::Base.logger
      ActionController::Base.logger = ActiveSupport::Logger.new(buffer)
      yield
      buffer.string
    ensure
      ActionController::Base.logger = previous_logger
    end
end
