# Rejects oversized POST bodies to the two public MCP/OAuth endpoints before any
# downstream middleware, Rails param parsing, or the MCP transport reads them.
#
# Both public endpoints otherwise read the whole body first and cap afterwards:
# Dynamic Client Registration materializes JSON params (Rails, unbounded size),
# and the MCP transport reads up to 4 MiB -- but only once the full request has
# been received. This middleware sits at the very front of the stack and bounds
# the request itself, so a giant body is never parsed or buffered by the app.
#
# It bounds the ACTUAL `rack.input` stream rather than trusting the
# `Content-Length` header, so a chunked, Content-Length-less, or header-lying
# body is caught just the same. A within-limit body is read into memory and the
# stream is replaced with a rewound in-memory copy, so Rails param parsing and
# the MCP transport downstream still see the full, rewindable body.
class McpBodyLimit
  # Match the MCP transport's own request ceiling so the two agree.
  MAX_BYTES = 4 * 1024 * 1024

  # Canonical top-level paths; both are unmounted, apex-host routes.
  PROTECTED_PATHS = [ "/mcp", "/oauth/register" ].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless guarded?(env)

    # Fast path: a declared oversize is rejected without reading the body at all.
    return too_large if declared_oversize?(env)

    input = env["rack.input"]
    return @app.call(env) if input.nil?

    input.rewind if input.respond_to?(:rewind)
    # Read one byte past the cap: if anything remains, the body is too large.
    buffer = input.read(MAX_BYTES + 1) || "".b
    return too_large if buffer.bytesize > MAX_BYTES

    # Reading consumed the stream, so hand downstream a rewound in-memory copy.
    env["rack.input"] = StringIO.new(buffer)
    @app.call(env)
  end

  private
    def guarded?(env)
      env["REQUEST_METHOD"] == "POST" && PROTECTED_PATHS.include?(normalized_path(env))
    end

    # Match exactly what Rails' router matches. It normalizes PATH_INFO before
    # routing -- collapsing repeated slashes and stripping a trailing one -- so
    # forms like `/oauth//register`, `//mcp`, or `/mcp/` all reach the protected
    # endpoints. Using the router's own normalization keeps the guard from being
    # bypassed by any slash variant the router still routes.
    def normalized_path(env)
      ActionDispatch::Journey::Router::Utils.normalize_path(env["PATH_INFO"].to_s)
    end

    def declared_oversize?(env)
      length = env["CONTENT_LENGTH"]
      !length.nil? && length.to_i > MAX_BYTES
    end

    def too_large
      [ 413, { "Content-Type" => "application/json" }, [ %({"error":"payload_too_large"}) ] ]
    end
end
