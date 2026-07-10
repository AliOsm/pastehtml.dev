require "test_helper"

class McpTools::ErrorSanitizerTest < ActiveSupport::TestCase
  # A tool that raises an exception whose message contains sensitive detail, to
  # prove the wrapper never forwards it to the client.
  class BoomTool < McpTools::BaseTool
    tool_name "boom_for_tests"
    description "Raises, for exception-sanitization tests."
    input_schema(type: "object", properties: {}, additionalProperties: false)

    def self.call(server_context:)
      raise "PG::InternalError: string contains null byte in /secret/path"
    end
  end

  test "an unexpected tool exception returns a generic error, not the raw message" do
    reported = []
    subscriber = Class.new do
      define_method(:report) do |error, handled:, severity:, source: nil, context: {}|
        reported << { error: error, source: source }
      end
    end.new
    Rails.error.subscribe(subscriber)

    response = BoomTool.call(server_context: { user: users(:alice) })

    assert response.error?
    assert_equal "internal_error", response.structured_content[:code]
    leaked = "#{response.structured_content.to_json} #{response.content.to_json}"
    assert_not_includes leaked, "null byte"
    assert_not_includes leaked, "PG::"
    assert_not_includes leaked, "/secret/path"

    # The real error is still captured for operators, just not exposed.
    assert(reported.any? { |r| r[:source] == "mcp-tool" && r[:error].message.include?("null byte") })
  ensure
    Rails.error.unsubscribe(subscriber) if subscriber
  end

  test "a real driver-level error (null byte in content) is sanitized, not leaked" do
    # A null byte in text is rejected by the pg driver / Postgres, raising an
    # exception whose message the SDK would otherwise embed in the response.
    content = "before" + 0.chr + "after"

    response = McpTools::CreatePaste.call(
      content: content, format: "html", server_context: { user: users(:alice) }
    )

    leaked = response.structured_content.to_json
    assert_not_includes leaked, "null byte"
    assert_not_includes leaked, "PG::"
    assert_equal "internal_error", response.structured_content[:code] if response.error?
  end
end
