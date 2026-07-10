require "test_helper"

class McpBodyLimitTest < ActiveSupport::TestCase
  # Echoes back whatever body it receives, so tests can prove the within-limit
  # stream was preserved and handed downstream intact.
  DOWNSTREAM = ->(env) { [ 200, { "Content-Type" => "text/plain" }, [ env["rack.input"].read ] ] }

  test "rejects an oversize body declared via Content-Length (fast path)" do
    status, _headers, body = call("/mcp", "POST", body: "", content_length: McpBodyLimit::MAX_BYTES + 1)

    assert_equal 413, status
    assert_includes body.join, "payload_too_large"
  end

  test "rejects an oversize actual body even with NO Content-Length (stream bound)" do
    status, = call("/oauth/register", "POST", body: oversize, content_length: :none)

    assert_equal 413, status
  end

  test "rejects an oversize actual body that lies about a small Content-Length" do
    status, = call("/mcp", "POST", body: oversize, content_length: 10)

    assert_equal 413, status
  end

  test "guards the trailing-slash route variants Rails also routes" do
    assert_equal 413, call("/mcp/", "POST", body: oversize, content_length: :none).first
    assert_equal 413, call("/oauth/register/", "POST", body: oversize, content_length: :none).first
  end

  test "passes an at-limit body through and preserves it for downstream" do
    payload = "a" * McpBodyLimit::MAX_BYTES
    status, _headers, body = call("/mcp", "POST", body: payload)

    assert_equal 200, status
    assert_equal payload.bytesize, body.join.bytesize, "downstream must receive the full body"
  end

  test "ignores non-POST methods and unguarded paths" do
    assert_equal 200, call("/mcp", "GET", body: oversize, content_length: :none).first
    assert_equal 200, call("/api/pastes", "POST", body: oversize, content_length: :none).first
  end

  test "is installed at the front of the application middleware stack" do
    klasses = Rails.application.middleware.map(&:klass)

    assert_includes klasses, McpBodyLimit
    assert_equal 0, klasses.index(McpBodyLimit), "should run before every other middleware"
  end

  private
    def oversize
      "a" * (McpBodyLimit::MAX_BYTES + 128)
    end

    def call(path, method, body: "", content_length: :from_body)
      env = { "REQUEST_METHOD" => method, "PATH_INFO" => path, "rack.input" => StringIO.new(body) }
      unless content_length == :none
        env["CONTENT_LENGTH"] = (content_length == :from_body ? body.bytesize : content_length).to_s
      end
      McpBodyLimit.new(DOWNSTREAM).call(env)
    end
end
