require "test_helper"

class McpBodyLimitTest < ActiveSupport::TestCase
  # Echoes back whatever body it receives, so tests can prove the within-limit
  # stream was preserved and handed downstream intact.
  DOWNSTREAM = ->(env) { [ 200, { "Content-Type" => "text/plain" }, [ env["rack.input"].read ] ] }

  test "rejects an oversize DCR body declared via Content-Length (fast path)" do
    status, _headers, body = call("/oauth/register", "POST", body: "", content_length: McpBodyLimit::OAUTH_MAX_BYTES + 1)

    assert_equal 413, status
    assert_includes body.join, "payload_too_large"
  end

  test "rejects an oversize actual OAuth body even with NO Content-Length (stream bound)" do
    status, = call("/oauth/token", "POST", body: over(McpBodyLimit::OAUTH_MAX_BYTES), content_length: :none)

    assert_equal 413, status
  end

  test "rejects an oversize OAuth body that lies about a small Content-Length" do
    status, = call("/oauth/token", "POST", body: over(McpBodyLimit::OAUTH_MAX_BYTES), content_length: 10)

    assert_equal 413, status
  end

  test "guards every OAuth POST endpoint, not just registration" do
    %w[/oauth/token /oauth/revoke /oauth/introspect /oauth/authorize /oauth/register].each do |path|
      assert_equal 413, call(path, "POST", body: over(McpBodyLimit::OAUTH_MAX_BYTES), content_length: :none).first, "#{path} should be guarded"
    end
  end

  test "guards every slash variant Rails' router normalizes to a protected path" do
    %w[/mcp/ //mcp /mcp// /oauth/register/ /oauth//register //oauth/register /oauth///register/].each do |path|
      status = call(path, "POST", body: over(McpBodyLimit::MCP_MAX_BYTES), content_length: :none).first
      assert_equal 413, status, "#{path} should be guarded"
    end
  end

  test "the /mcp endpoint allows a larger body than the OAuth endpoints (fits a JSON-escaped 2 MB paste)" do
    body = "a" * (McpBodyLimit::OAUTH_MAX_BYTES + 1_000_000) # bigger than the OAuth cap, within the MCP cap

    assert_equal 413, call("/oauth/token", "POST", body: body, content_length: :none).first, "OAuth cap should reject it"
    assert_equal 200, call("/mcp", "POST", body: body, content_length: :none).first, "MCP cap should allow it"
  end

  test "passes an at-limit /mcp body through and preserves it for downstream" do
    payload = "a" * McpBodyLimit::MCP_MAX_BYTES
    status, _headers, body = call("/mcp", "POST", body: payload)

    assert_equal 200, status
    assert_equal payload.bytesize, body.join.bytesize, "downstream must receive the full body"
  end

  test "guards a guarded path on any verb, including a body-bearing DELETE" do
    # DELETE /oauth/authorize is a real Doorkeeper route; a POST-only guard let an
    # oversized DELETE body through.
    assert_equal 413, call("/oauth/authorize", "DELETE", body: over(McpBodyLimit::OAUTH_MAX_BYTES), content_length: :none).first
    # An abnormal oversized GET body on a guarded path is bounded too.
    assert_equal 413, call("/mcp", "GET", body: over(McpBodyLimit::MCP_MAX_BYTES), content_length: :none).first
  end

  test "ignores unguarded paths and lets an empty-body request through" do
    assert_equal 200, call("/api/pastes", "POST", body: over(McpBodyLimit::MCP_MAX_BYTES), content_length: :none).first
    assert_equal 200, call("/mcp", "GET", body: "").first
  end

  test "is installed at the front of the application middleware stack" do
    klasses = Rails.application.middleware.map(&:klass)

    assert_includes klasses, McpBodyLimit
    assert_equal 0, klasses.index(McpBodyLimit), "should run before every other middleware"
  end

  private
    def over(limit)
      "a" * (limit + 128)
    end

    def call(path, method, body: "", content_length: :from_body)
      env = { "REQUEST_METHOD" => method, "PATH_INFO" => path, "rack.input" => StringIO.new(body) }
      unless content_length == :none
        env["CONTENT_LENGTH"] = (content_length == :from_body ? body.bytesize : content_length).to_s
      end
      McpBodyLimit.new(DOWNSTREAM).call(env)
    end
end
