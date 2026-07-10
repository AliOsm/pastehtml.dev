require "test_helper"

# config/initializers/mcp.rb wires the SDK's GLOBAL exception reporter -- the one
# the Streamable HTTP transport uses for pre-dispatch (body read/parse) failures,
# which the per-server reporter in McpController does not cover.
class McpConfigurationTest < ActiveSupport::TestCase
  test "the global MCP reporter is configured (not the SDK no-op default)" do
    assert MCP.configuration.exception_reporter?, "expected a global exception reporter"
  end

  test "it routes transport failures to Rails.error and drops the raw request context" do
    reported = []
    subscriber = Class.new do
      define_method(:report) do |error, handled:, severity:, source: nil, context: {}|
        reported << { error: error, source: source, context: context }
      end
    end.new
    Rails.error.subscribe(subscriber)

    # The transport passes the raw body as context at its call site; simulate it.
    MCP.configuration.exception_reporter.call(RuntimeError.new("transport boom"), { request: "SECRET PASTE BODY" })

    boom = reported.find { |r| r[:error].is_a?(RuntimeError) && r[:error].message == "transport boom" }
    assert boom, "expected the transport exception to be reported to Rails.error"
    assert_equal "mcp-transport", boom[:source]
    assert_not boom[:context].key?(:request), "raw request body must not be forwarded"
    assert_not_includes boom[:context].values.map(&:to_s).join, "SECRET PASTE BODY"
  ensure
    Rails.error.unsubscribe(subscriber) if subscriber
  end
end
