# Global MCP SDK configuration.
#
# The Streamable HTTP transport rescues failures that happen BEFORE a request
# reaches the server -- reading and parsing the request body -- and reports them
# through the SDK's GLOBAL configuration (MCP.configuration.exception_reporter).
# That is distinct from the per-request reporter McpController installs on each
# MCP::Server, which only covers tool exceptions. Without a global reporter,
# transport-level failures 500 silently and never reach Rails' error tracking.
#
# Route them to Rails.error. Deliberately DROP the SDK-supplied context: some
# transport call sites pass the raw request body (`{ request: body_string }`),
# which can carry a private paste's full content.
MCP.configure do |config|
  config.exception_reporter = lambda do |exception, _sdk_context|
    Rails.error.report(exception, handled: true, source: "mcp-transport")
  end
end
