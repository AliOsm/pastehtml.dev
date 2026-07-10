# Rejects oversized request bodies to the public MCP and OAuth endpoints before
# any downstream middleware, Rails param parsing, or the MCP transport reads
# them. The cap is keyed on the request path, so it applies to every verb those
# endpoints serve (POST, and also e.g. DELETE /oauth/authorize), not just POST.
#
# These endpoints otherwise read the whole body first and cap afterwards: the
# OAuth endpoints (/oauth/token, /oauth/authorize, /oauth/revoke, /oauth/
# introspect, /oauth/register) materialize form/JSON params through Rails (and
# resource-indicator enforcement re-reads the form body), and the MCP transport
# reads the body only once the full request has arrived. This middleware sits at
# the very front of the stack and bounds the request itself, so a giant body is
# never parsed or buffered by the app.
#
# It bounds the ACTUAL `rack.input` stream rather than trusting the
# `Content-Length` header, so a chunked, Content-Length-less, or header-lying
# body is caught just the same. A within-limit body is read into memory and the
# stream is replaced with a rewound in-memory copy, so Rails param parsing and
# the MCP transport downstream still see the full, rewindable body.
class McpBodyLimit
  # The /mcp endpoint carries paste content (up to a 2 MB paste, which balloons
  # under JSON-string escaping -- quote/backslash-heavy HTML can roughly double),
  # so its ceiling is generous. It is authenticated and rate-limited, which
  # bounds the abuse surface. The MCP transport is configured with this same
  # ceiling (see McpController) so the two agree.
  MCP_MAX_BYTES = 8 * 1024 * 1024

  # OAuth requests are tiny (a token exchange, a registration); a much tighter
  # cap bounds the unauthenticated form-parsing DoS surface.
  OAUTH_MAX_BYTES = 1 * 1024 * 1024

  MCP_PATH = "/mcp"
  OAUTH_PREFIX = "/oauth/"

  def initialize(app)
    @app = app
  end

  def call(env)
    limit = limit_for(env)
    return @app.call(env) if limit.nil?

    # Fast path: a declared oversize is rejected without reading the body at all.
    return too_large if declared_oversize?(env, limit)

    input = env["rack.input"]
    return @app.call(env) if input.nil?

    input.rewind if input.respond_to?(:rewind)
    # Read one byte past the cap: if anything remains, the body is too large.
    buffer = input.read(limit + 1) || "".b
    return too_large if buffer.bytesize > limit

    # Reading consumed the stream, so hand downstream a rewound in-memory copy.
    env["rack.input"] = StringIO.new(buffer)
    @app.call(env)
  end

  private
    # The byte ceiling for this request, or nil if the endpoint is not guarded.
    # Keyed on PATH only, not method: Doorkeeper serves several verbs on the same
    # OAuth paths (e.g. DELETE /oauth/authorize), and any body-bearing verb -- not
    # just POST -- can carry an oversized payload. Body-less verbs (GET/HEAD) just
    # see an empty stream, so guarding them costs nothing.
    def limit_for(env)
      path = normalized_path(env)
      return MCP_MAX_BYTES if path == MCP_PATH
      return OAUTH_MAX_BYTES if path.start_with?(OAUTH_PREFIX)

      nil
    end

    # Match exactly what Rails' router matches. It normalizes PATH_INFO before
    # routing -- collapsing repeated slashes and stripping a trailing one -- so
    # forms like `/oauth//register`, `//mcp`, or `/mcp/` all reach the protected
    # endpoints. Using the router's own normalization keeps the guard from being
    # bypassed by any slash variant the router still routes.
    def normalized_path(env)
      ActionDispatch::Journey::Router::Utils.normalize_path(env["PATH_INFO"].to_s)
    end

    def declared_oversize?(env, limit)
      length = env["CONTENT_LENGTH"]
      !length.nil? && length.to_i > limit
    end

    def too_large
      [ 413, { "Content-Type" => "application/json" }, [ %({"error":"payload_too_large"}) ] ]
    end
end
