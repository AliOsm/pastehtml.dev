# Rejects oversized POST bodies to the two public MCP/OAuth endpoints before any
# downstream middleware, Rails param parsing, or the MCP transport reads them.
#
# Both public endpoints otherwise read the whole body first and cap afterwards:
# Dynamic Client Registration materializes JSON params (Rails, unbounded size),
# and the MCP transport reads up to 4 MiB -- but only once the full request has
# already been received and buffered. This middleware runs at the very front of
# the stack and rejects a declared-oversize request outright, so a giant body is
# never parsed or copied by the app.
#
# It caps the declared Content-Length, which is the normal path for the CLI
# agents (Claude Code, Codex) that use these endpoints. A body sent with no
# Content-Length (e.g. chunked transfer) falls through to the transport's own
# 4 MiB streaming read cap on /mcp and Rails' 100-level nesting limit on the DCR
# JSON -- so it is defense-in-depth, not the only limit.
class McpBodyLimit
  # Match the MCP transport's own request ceiling so the two agree.
  MAX_BYTES = 4 * 1024 * 1024

  # Exact top-level paths; both are unmounted, apex-host routes.
  PROTECTED_PATHS = [ "/mcp", "/oauth/register" ].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    return too_large if guarded?(env) && declared_oversize?(env)

    @app.call(env)
  end

  private
    def guarded?(env)
      env["REQUEST_METHOD"] == "POST" && PROTECTED_PATHS.include?(env["PATH_INFO"])
    end

    def declared_oversize?(env)
      length = env["CONTENT_LENGTH"]
      !length.nil? && length.to_i > MAX_BYTES
    end

    def too_large
      [ 413, { "Content-Type" => "application/json" }, [ %({"error":"payload_too_large"}) ] ]
    end
end
