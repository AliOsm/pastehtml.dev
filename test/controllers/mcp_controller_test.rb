require "test_helper"

# Fake tools registered into the McpTools registry for the scope/rate-limit
# tests, then removed in teardown so the global registry stays clean. They are
# never actually invoked except on the read happy-path (which proves the peek
# rewound the body for the transport).
class FakeMcpReadTool < MCP::Tool
  tool_name "fake_read"
  description "A fake read-only tool for tests."

  def self.call(**_args)
    MCP::Tool::Response.new([ { type: "text", text: "read ok" } ])
  end
end

class FakeMcpWriteTool < MCP::Tool
  tool_name "fake_write"
  description "A fake write tool for tests."

  def self.call(**_args)
    MCP::Tool::Response.new([ { type: "text", text: "write ok" } ])
  end
end

class McpControllerTest < ActionDispatch::IntegrationTest
  RESOURCE = McpOauth::CONFIG[:resource_uri]
  CANONICAL_ORIGIN = "http://www.example.com".freeze

  setup do
    @user = users(:alice)
    @application = oauth_applications(:mcp_client)
    McpTools.register(FakeMcpReadTool, scope: "mcp:read")
    McpTools.register(FakeMcpWriteTool, scope: "mcp:write")
  end

  teardown do
    McpTools.deregister(FakeMcpReadTool)
    McpTools.deregister(FakeMcpWriteTool)
  end

  # --- Happy path ----------------------------------------------------------

  test "valid token + POST initialize returns a 200 JSON-RPC result" do
    mcp_post(initialize_body, token: read_write_token.plaintext_token)

    assert_response :ok
    result = response.parsed_body["result"]
    assert result.present?, "expected a JSON-RPC result"
    assert_equal "pastehtml", result.dig("serverInfo", "name")
    assert result["protocolVersion"].present?
    assert_match(/permanent/, result["instructions"].to_s)
  end

  test "a notification is acknowledged with 202 and a truly empty body" do
    mcp_post(notification_body, token: read_write_token.plaintext_token)

    assert_response 202
    assert_equal "", response.body
  end

  test "a read tools/call succeeds, proving the peek rewound the full body" do
    mcp_post(tools_call_body("fake_read"), token: read_token.plaintext_token)

    assert_response :ok
    assert_includes response.body, "read ok"
  end

  # --- Verb handling (stateless transport) ---------------------------------

  test "GET /mcp with a valid token is 405, never a routing 404" do
    get "/mcp", headers: auth_headers(read_write_token.plaintext_token).merge("Accept" => "text/event-stream")

    assert_response :method_not_allowed
  end

  test "DELETE /mcp with a valid token is handled by the transport, not 404/500" do
    delete "/mcp", headers: auth_headers(read_write_token.plaintext_token)

    assert_not_includes [ 404, 500 ], response.status
  end

  # --- RFC 6750 split 401 challenges ----------------------------------------

  test "no Authorization header yields a 401 challenge with no error attribute" do
    mcp_post(initialize_body, token: nil)

    assert_response :unauthorized
    challenge = response.headers["WWW-Authenticate"]
    assert challenge.present?
    assert_not_includes challenge, "error="
    assert_includes challenge, %(resource_metadata=)
    assert_includes challenge, %(scope="mcp:read mcp:write")
  end

  test "a garbage token yields error=invalid_token" do
    mcp_post(initialize_body, token: "not-a-real-token")

    assert_invalid_token
  end

  test "a revoked token yields error=invalid_token" do
    token = read_write_token
    token.update!(revoked_at: Time.current)

    mcp_post(initialize_body, token: token.plaintext_token)

    assert_invalid_token
  end

  test "an expired token yields error=invalid_token" do
    token = read_write_token
    # expires_in is 1 hour; backdating creation puts expiry in the past.
    token.update!(created_at: 2.hours.ago)

    mcp_post(initialize_body, token: token.plaintext_token)

    assert_invalid_token
  end

  test "a token bound to another resource (wrong audience) yields error=invalid_token" do
    token = mint_token(scopes: "mcp:read mcp:write", resource: "https://evil.example.com/mcp")

    mcp_post(initialize_body, token: token.plaintext_token)

    assert_invalid_token
  end

  # --- Origin guard (runs before authentication) ----------------------------

  test "a foreign Origin with a valid token is 403 from the Origin guard" do
    mcp_post(initialize_body, token: read_write_token.plaintext_token, origin: "https://evil.example.com")

    assert_response :forbidden
    assert_equal "forbidden_origin", response.parsed_body["error"]
    assert_nil response.headers["WWW-Authenticate"]
  end

  test "a foreign Origin with no token is 403, not 401 (proves guard runs first)" do
    mcp_post(initialize_body, token: nil, origin: "https://evil.example.com")

    assert_response :forbidden
    assert_equal "forbidden_origin", response.parsed_body["error"]
  end

  test "the canonical Origin passes the guard" do
    mcp_post(initialize_body, token: read_write_token.plaintext_token, origin: CANONICAL_ORIGIN)

    assert_response :ok
  end

  # --- Scope step-up --------------------------------------------------------

  test "a read-only token calling a write tool gets a 403 full-scope step-up" do
    mcp_post(tools_call_body("fake_write"), token: read_token.plaintext_token)

    assert_response :forbidden
    assert_equal "insufficient_scope", response.parsed_body["error"]
    challenge = response.headers["WWW-Authenticate"]
    assert_includes challenge, %(error="insufficient_scope")
    assert_includes challenge, %(scope="mcp:read mcp:write")
    assert_includes challenge, %(resource_metadata=)
  end

  test "calling an unknown tool is not a 403 (SDK answers instead)" do
    mcp_post(tools_call_body("nope_not_a_tool"), token: read_token.plaintext_token)

    assert_not_equal 403, response.status
    assert_response :ok
    assert response.parsed_body["error"].present?, "expected a JSON-RPC error from the SDK"
  end

  # --- Bounded, rewind-safe peek robustness ---------------------------------

  test "a deeply nested body reaches the transport's error handling, no exception" do
    # 80 levels: past the peek's cap (20) and the transport's cap (64), but
    # under Rails' own param-parser nesting limit, so the peek steps aside and
    # the transport returns a JSON-RPC parse error rather than the app 500ing.
    mcp_post(nested_json(80), token: read_write_token.plaintext_token)

    assert_not_equal 500, response.status
    assert_response :bad_request
  end

  test "an oversized body reaches the transport's oversize handling, no 500" do
    filler = "a" * (McpController::MAX_REQUEST_BYTES + 128)
    body = %({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"filler":"#{filler}"}})

    mcp_post(body, token: read_write_token.plaintext_token)

    assert_not_equal 500, response.status
    assert_response :content_too_large
  end

  # --- Throttled last_used_at bump ------------------------------------------

  test "a successful request sets last_used_at when it was nil" do
    token = read_write_token
    assert_nil token.last_used_at

    travel_to Time.current do
      mcp_post(initialize_body, token: token.plaintext_token)
    end

    assert_response :ok
    assert_in_delta Time.current.to_f, token.reload.last_used_at.to_f, 2
  end

  test "a second request within the throttle window does not change last_used_at" do
    token = read_write_token

    first_time = Time.current
    travel_to(first_time) { mcp_post(initialize_body, token: token.plaintext_token) }
    first_last_used_at = token.reload.last_used_at

    travel_to(first_time + 5.minutes) { mcp_post(initialize_body, token: token.plaintext_token) }

    assert_equal first_last_used_at, token.reload.last_used_at
  end

  test "a request after the throttle window elapses bumps last_used_at" do
    token = read_write_token

    first_time = Time.current
    travel_to(first_time) { mcp_post(initialize_body, token: token.plaintext_token) }
    first_last_used_at = token.reload.last_used_at

    later = first_time + 16.minutes
    travel_to(later) { mcp_post(initialize_body, token: token.plaintext_token) }

    assert_operator token.reload.last_used_at, :>, first_last_used_at
    assert_in_delta later.to_f, token.last_used_at.to_f, 2
  end

  test "failed authentication bumps nothing" do
    token = read_write_token
    assert_nil token.last_used_at

    mcp_post(initialize_body, token: "not-a-real-token")

    assert_response :unauthorized
    # The real token was never presented, so authenticate_token! never ran the
    # bump for it -- it must remain untouched by this unrelated failed request.
    assert_nil token.reload.last_used_at
  end

  test "a revoked token's failed authentication does not bump last_used_at" do
    token = read_write_token
    token.update!(revoked_at: Time.current)

    mcp_post(initialize_body, token: token.plaintext_token)

    assert_response :unauthorized
    assert_nil token.reload.last_used_at
  end

  # --- Write rate limit -----------------------------------------------------

  test "the 21st write tools/call in a minute is rate limited" do
    token = read_write_token
    minute_key = "mcp-write-rate:minute:#{@user.id}"

    # The test cache is a null_store (increment returns nil), so inject a real
    # counter on the store the controller uses and pre-seed it at the minute
    # cap. The next write call increments to 21 and is rejected.
    with_counting_cache_store(minute_key => WRITE_LIMIT) do
      mcp_post(tools_call_body("fake_write"), token: token.plaintext_token)
    end

    assert_response :too_many_requests
    assert_equal "rate_limited", response.parsed_body["error"]
  end

  private
    WRITE_LIMIT = McpController::WRITE_LIMIT_PER_MINUTE

    def mcp_post(body, token:, origin: nil, accept: "application/json, text/event-stream")
      headers = {
        "Content-Type" => "application/json",
        "Accept" => accept
      }
      headers["Authorization"] = "Bearer #{token}" if token
      headers["Origin"] = origin if origin
      post "/mcp", params: body, headers: headers
    end

    def auth_headers(token)
      { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
    end

    def mint_token(scopes:, resource: RESOURCE, expires_in: 3600, user: @user)
      Doorkeeper::AccessToken.create!(
        application: @application,
        resource_owner_id: user.id,
        scopes: scopes,
        expires_in: expires_in,
        resource: resource
      )
    end

    def read_write_token
      @read_write_token ||= mint_token(scopes: "mcp:read mcp:write")
    end

    def read_token
      @read_token ||= mint_token(scopes: "mcp:read")
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

    def notification_body
      { jsonrpc: "2.0", method: "notifications/initialized" }.to_json
    end

    def tools_call_body(name)
      { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: name, arguments: {} } }.to_json
    end

    def nested_json(depth)
      inner = "1"
      depth.times { inner = %({"a":#{inner}}) }
      inner
    end

    def assert_invalid_token
      assert_response :unauthorized
      assert_includes response.headers["WWW-Authenticate"], %(error="invalid_token")
    end

    # Mirrors the registrations controller test: swap `increment` on the exact
    # store object the controller uses so the throttle can be exercised without
    # touching production behavior. `preseed` sets starting counts per key.
    def with_counting_cache_store(preseed = {})
      store = McpController.cache_store
      counts = Hash.new(0).merge(preseed)
      store.define_singleton_method(:increment) do |key, amount = 1, **_opts|
        counts[key] += amount
      end
      yield counts
    ensure
      store.singleton_class.remove_method(:increment)
    end
end
