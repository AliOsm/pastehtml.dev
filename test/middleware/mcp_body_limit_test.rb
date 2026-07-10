require "test_helper"

class McpBodyLimitTest < ActiveSupport::TestCase
  DOWNSTREAM = ->(_env) { [ 200, { "Content-Type" => "text/plain" }, [ "ok" ] ] }

  test "rejects an oversize POST to /mcp with 413 before reaching downstream" do
    status, _headers, body = call("/mcp", "POST", McpBodyLimit::MAX_BYTES + 1)

    assert_equal 413, status
    assert_includes body.join, "payload_too_large"
  end

  test "rejects an oversize POST to /oauth/register with 413" do
    status, = call("/oauth/register", "POST", McpBodyLimit::MAX_BYTES + 1)

    assert_equal 413, status
  end

  test "passes a body at the limit through to downstream" do
    status, = call("/mcp", "POST", McpBodyLimit::MAX_BYTES)

    assert_equal 200, status
  end

  test "passes a request with no Content-Length through (relies on transport cap)" do
    status, = call("/mcp", "POST", nil)

    assert_equal 200, status
  end

  test "ignores non-POST methods and unguarded paths" do
    assert_equal 200, call("/mcp", "GET", McpBodyLimit::MAX_BYTES + 1).first
    assert_equal 200, call("/api/pastes", "POST", McpBodyLimit::MAX_BYTES + 1).first
  end

  test "is installed at the front of the application middleware stack" do
    klasses = Rails.application.middleware.map(&:klass)

    assert_includes klasses, McpBodyLimit
    assert_equal 0, klasses.index(McpBodyLimit), "should run before every other middleware"
  end

  private
    def call(path, method, content_length)
      env = { "REQUEST_METHOD" => method, "PATH_INFO" => path }
      env["CONTENT_LENGTH"] = content_length.to_s unless content_length.nil?
      McpBodyLimit.new(DOWNSTREAM).call(env)
    end
end
