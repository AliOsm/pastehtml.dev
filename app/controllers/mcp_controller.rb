# The remote MCP (Model Context Protocol) endpoint. Coding agents (Claude Code,
# Codex CLI, ...) speak Streamable HTTP JSON-RPC here, authorized by a
# Doorkeeper OAuth bearer token that stands in for the signed-in user -- no
# pht_ API key involved.
#
# ActionController::API on purpose (the Api::BaseController pattern): no session
# cookie, no CSRF, no HTML layout. The request is handled entirely by the mcp
# gem's transport; this controller only layers the guards the transport does
# not (or cannot) do on its own, in this strict order:
#
#   1. Origin guard        -- reject foreign browser origins before any DB work.
#   2. Bearer auth         -- RFC 6750 split 401 challenges.
#   3. Scope + rate limits -- a bounded, rewind-safe peek at the JSON-RPC body
#                             pre-authorizes tools/call and meters writes.
#   4. Dispatch            -- hand the untouched request to the transport and
#                             pass its Rack triple straight back.
class McpController < ActionController::API
  # The canonical browser origin (scheme + host + port) derived once from the
  # trusted issuer -- never from request headers, which an attacker controls.
  CANONICAL_ORIGIN = begin
    uri = URI.parse(McpOauth::CONFIG[:issuer])
    default_port = uri.scheme == "https" ? 443 : 80
    authority = uri.port && uri.port != default_port ? "#{uri.host}:#{uri.port}" : uri.host
    "#{uri.scheme}://#{authority}".downcase.freeze
  end

  # The full-access scope list every challenge advertises. Naming the full set
  # (not just a missing scope) on the insufficient_scope step-up prevents a
  # client from re-authorizing against a narrower scope and losing read access
  # (scope oscillation).
  CHALLENGE_SCOPE = "#{McpTools::READ_SCOPE} #{McpTools::WRITE_SCOPE}".freeze

  # The transport reads at most this many bytes before rejecting (4 MiB); the
  # pre-dispatch peek honors the same bound so it never becomes a bypass of it.
  MAX_REQUEST_BYTES = MCP::Server::Transports::StreamableHTTPTransport::DEFAULT_MAX_REQUEST_BYTES

  # Conservative nesting bound for the peek. Deeper-but-still-parseable bodies
  # simply cause the peek to step aside (returns nil) and reach the transport,
  # which applies its own nesting cap.
  PEEK_MAX_NESTING = 20

  # Write-tool budget per token-owning user, mirroring the REST API's paste
  # limits -- pastes can never be deleted, so unmetered writes are unbounded
  # storage growth.
  WRITE_LIMIT_PER_MINUTE = 20
  WRITE_LIMIT_PER_DAY = 1000

  before_action :enforce_origin!
  before_action :authenticate_token!
  before_action :enforce_tool_scope!
  before_action :enforce_write_rate_limit!

  def handle
    server = MCP::Server.new(
      name: "pastehtml",
      version: McpTools::VERSION,
      instructions: McpTools::INSTRUCTIONS,
      tools: McpTools.for_scopes(token_scopes),
      server_context: { user: current_token_user }
    )
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      server,
      stateless: true,
      # The transport's default Host allowlist is loopback-only, so production
      # (and the test host) would 403 without this. Origin is validated above.
      allowed_hosts: [ McpOauth::CONFIG[:host] ]
    )

    status, headers, body = transport.handle_request(request)
    headers.each { |key, value| response.headers[key] = value }

    if body.nil? || (body.respond_to?(:empty?) && body.empty?)
      # An accepted notification is 202 with a truly empty body -- never a
      # literal JSON "null" or "{}". `head` renders no body.
      head status
    else
      # Pass the Rack body through untouched (JSON-RPC result, transport error,
      # or the stateless 405/DELETE bodies) rather than re-serializing it.
      self.status = status
      self.response_body = body
    end
  end

  private
    # --- Step 1: Origin guard ------------------------------------------------

    # Absent Origin is the normal case for CLI agents and passes. A present
    # Origin must be the canonical app origin, or the request is refused before
    # any authentication or database work happens.
    def enforce_origin!
      origin = request.headers["Origin"]
      return if origin.blank?
      return if origin.strip.downcase == CANONICAL_ORIGIN

      render json: { error: "forbidden_origin" }, status: :forbidden
    end

    # --- Step 2: Bearer authentication --------------------------------------

    def authenticate_token!
      token_value = bearer_token
      # No credentials at all is not an error condition (RFC 6750): challenge
      # without an `error` attribute so the client starts the discovery flow.
      return challenge_unauthorized if token_value.blank?

      access_token = Doorkeeper::AccessToken.by_token(token_value)
      if access_token.nil? || !access_token.accessible? ||
         !mcp_scoped?(access_token) || wrong_audience?(access_token)
        return challenge_unauthorized(error: "invalid_token")
      end

      @current_access_token = access_token
    end

    def mcp_scoped?(access_token)
      access_token.scopes.to_a.any? { |scope| scope.start_with?("mcp:") }
    end

    # RFC 8707: the token must have been issued for this exact resource. Storage
    # is normalized to the canonical URI, so exact equality is safe.
    def wrong_audience?(access_token)
      access_token.resource != McpOauth::CONFIG[:resource_uri]
    end

    def challenge_unauthorized(error: nil)
      response.headers["WWW-Authenticate"] = www_authenticate(error: error)
      render json: { error: error || "unauthorized" }, status: :unauthorized
    end

    def www_authenticate(error: nil)
      parts = []
      parts << %(error="#{error}") if error
      parts << %(resource_metadata="#{McpOauth::CONFIG[:protected_resource_metadata_url]}")
      parts << %(scope="#{CHALLENGE_SCOPE}")
      "Bearer #{parts.join(", ")}"
    end

    # --- Step 3: scope enforcement + write rate limits ----------------------

    def enforce_tool_scope!
      body = mcp_request_body
      return if body.nil?
      return unless body[:method] == "tools/call"

      required = McpTools.required_scope(body.dig(:params, :name))
      # Unknown tool (nil) falls through so the SDK answers "unknown tool"; a
      # scope the token already holds is fine.
      return if required.nil? || token_scopes.include?(required)

      challenge_insufficient_scope
    end

    def challenge_insufficient_scope
      response.headers["WWW-Authenticate"] =
        %(Bearer error="insufficient_scope", scope="#{CHALLENGE_SCOPE}", ) +
        %(resource_metadata="#{McpOauth::CONFIG[:protected_resource_metadata_url]}")
      render json: { error: "insufficient_scope" }, status: :forbidden
    end

    def enforce_write_rate_limit!
      body = mcp_request_body
      return if body.nil?
      return unless body[:method] == "tools/call"
      return unless McpTools.required_scope(body.dig(:params, :name)) == McpTools::WRITE_SCOPE

      user_id = current_token_user&.id
      return if user_id.nil?

      # Mirror the Rails `rate_limit` macro's semantics (increment a per-window
      # counter, reject once it exceeds the cap) inline so the check can be
      # conditional on the parsed body. Two sequential windows, minute then day,
      # matching two stacked `rate_limit` before_actions -- the second window is
      # only touched if the first passed. In the test env the cache is a
      # null_store whose `increment` returns nil, so this is a no-op unless a
      # real counter is injected (see the controller test).
      return render_rate_limited unless under_write_limit?(write_rate_key("minute", user_id), WRITE_LIMIT_PER_MINUTE, 1.minute)
      render_rate_limited unless under_write_limit?(write_rate_key("day", user_id), WRITE_LIMIT_PER_DAY, 1.day)
    end

    def under_write_limit?(key, limit, window)
      count = self.class.cache_store.increment(key, 1, expires_in: window)
      count.nil? || count <= limit
    end

    def write_rate_key(window, user_id)
      "mcp-write-rate:#{window}:#{user_id}"
    end

    def render_rate_limited
      render json: { error: "rate_limited" }, status: :too_many_requests
    end

    # A bounded, rewind-safe peek at the JSON-RPC body, parsed once and memoized
    # for the scope check and the rate-limit check. It must not consume the body
    # the transport needs, and must not do the transport's job of rejecting
    # oversized/malformed/batched bodies -- for any of those it returns nil and
    # steps aside so the transport applies its own error handling.
    def mcp_request_body
      return @mcp_request_body if defined?(@mcp_request_body)

      @mcp_request_body = peek_request_body
    end

    def peek_request_body
      return nil unless request.post?

      request.body.rewind if request.body.respond_to?(:rewind)
      raw = request.body.read(MAX_REQUEST_BYTES + 1)
      # Oversized: leave it to the transport's 413.
      return nil if raw.nil? || raw.bytesize > MAX_REQUEST_BYTES

      parsed = JSON.parse(raw, symbolize_names: true, max_nesting: PEEK_MAX_NESTING)
      # Only a single top-level object is ours to inspect; arrays/scalars (and
      # too-deep or malformed bodies, via the rescue) are the transport's.
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    ensure
      request.body.rewind if request.body.respond_to?(:rewind)
    end

    # --- Token-derived helpers ----------------------------------------------

    def token_scopes
      @token_scopes ||= @current_access_token.scopes.to_a
    end

    def current_token_user
      return @current_token_user if defined?(@current_token_user)

      @current_token_user = @current_access_token && User.find_by(id: @current_access_token.resource_owner_id)
    end

    def bearer_token
      request.authorization.to_s[/\ABearer\s+(.+)\z/i, 1]&.strip.presence
    end
end
