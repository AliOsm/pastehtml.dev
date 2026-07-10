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

  # The request ceiling for /mcp, shared with the front-of-stack McpBodyLimit so
  # the transport, the pre-dispatch peek, and the middleware all agree. Sized to
  # fit a full 2 MB paste for typical clients; a client whose JSON encoder emits
  # six-byte \uXXXX escapes for < > & may not fit content dominated by those
  # characters (see the encoding caveat in public/llms.txt and McpBodyLimit).
  MAX_REQUEST_BYTES = McpBodyLimit::MCP_MAX_BYTES

  # The peek MUST use the transport's own nesting bound, not a lower one. If the
  # peek stopped parsing before the transport did, a body nested between the two
  # limits would classify as nil here (skipping the scope + rate-limit gates)
  # yet still parse and DISPATCH in the transport -- a gate bypass. Sharing the
  # constant guarantees: anything the transport will execute, the peek can
  # classify; anything too deep for the peek is also too deep for the transport
  # (rejected there), so it never runs.
  PEEK_MAX_NESTING = MCP::Server::Transports::StreamableHTTPTransport::MAX_JSON_NESTING

  # Only tools are implemented -- no prompts, resources, or logging, and the
  # stateless server has no session to push list-change notifications over. The
  # SDK's default capabilities advertise all of those; declare the real set so
  # the initialize response does not promise what this server cannot do.
  SERVER_CAPABILITIES = { tools: { listChanged: false } }.freeze

  # Throttle window for the `last_used_at` usage bump below -- heavy agent
  # traffic hits /mcp on every tool call, so writing on every request would be
  # one UPDATE per request. nil counts as stale (first use).
  LAST_USED_AT_STALE_AFTER = 15.minutes

  # Write-tool budget per token-owning user, mirroring the REST API's paste
  # limits -- pastes can never be deleted, so unmetered writes are unbounded
  # storage growth.
  WRITE_LIMIT_PER_MINUTE = 20
  WRITE_LIMIT_PER_DAY = 1000

  before_action :enforce_origin!
  before_action :authenticate_token!
  before_action :reject_non_object_params!
  before_action :enforce_tool_scope!
  before_action :enforce_write_rate_limit!

  def handle
    server = MCP::Server.new(
      name: "pastehtml",
      version: McpTools::VERSION,
      instructions: McpTools::INSTRUCTIONS,
      capabilities: SERVER_CAPABILITIES,
      tools: McpTools.for_scopes(token_scopes),
      server_context: { user: current_token_user },
      # Turn on the SDK's server-side result validation so a successful tool
      # result that does not match its declared output_schema is caught here
      # rather than shipped to the agent. Argument validation is already on by
      # the SDK default; error results are exempt (they follow the tool error
      # contract, not the success schema). exception_reporter routes tool/
      # transport exceptions -- which the SDK otherwise turns into JSON-RPC
      # errors and swallows -- into Rails' error reporter.
      configuration: MCP::Configuration.new(
        validate_tool_call_results: true,
        exception_reporter: method(:report_mcp_exception)
      )
    )
    transport = MCP::Server::Transports::StreamableHTTPTransport.new(
      server,
      stateless: true,
      # The transport's default Host allowlist is loopback-only, so production
      # (and the test host) would 403 without this. Origin is validated above.
      allowed_hosts: [ McpOauth::CONFIG[:host] ],
      # Raise the transport's own body ceiling to match the middleware and the
      # peek, so a legitimate 2 MB paste (JSON-escaped) is not rejected here.
      max_request_bytes: MAX_REQUEST_BYTES
    )

    status, headers, body = transport.handle_request(request)
    headers.each { |key, value| response.headers[key] = value }

    sanitized = sanitize_internal_error_body(body, response.headers["Content-Type"])

    if sanitized
      # A JSON-RPC internal error whose `data` carried a raw exception message
      # (from SDK-level validation/dispatch, outside the per-tool wrapper) --
      # replaced with a leak-free copy. Content-Length must track the new body.
      response.headers["Content-Length"] = sanitized.bytesize.to_s
      self.status = status
      self.response_body = [ sanitized ]
    elsif body.nil? || (body.respond_to?(:empty?) && body.empty?)
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
    # --- JSON-RPC boundary error sanitizing ----------------------------------

    # The SDK wraps any exception raised during request validation/dispatch --
    # BEFORE a request reaches a tool, so outside BaseTool's per-tool wrapper --
    # into a -32603 "Internal error" whose `data` holds the raw Ruby message
    # (e.g. array `params` -> "no implicit conversion of Symbol into Integer").
    # Strip that `data` at the boundary so implementation details never ship.
    # Returns the rewritten JSON string when it changed anything, else nil (the
    # untouched body is passed through). Only JSON responses are inspected;
    # SSE/empty bodies are left alone.
    def sanitize_internal_error_body(body, content_type)
      return nil unless content_type.to_s.include?("application/json")
      return nil unless body.respond_to?(:each)

      raw = +""
      body.each { |part| raw << part.to_s }
      return nil if raw.empty?

      parsed = JSON.parse(raw)
      changed = redact_internal_error!(parsed)
      changed ? JSON.generate(parsed) : nil
    rescue JSON::ParserError
      nil
    end

    # Drops `data` from a -32603 error object, in a single response or a batch
    # array. Returns whether anything was redacted.
    def redact_internal_error!(parsed)
      case parsed
      when Array
        parsed.map { |element| redact_internal_error!(element) }.any?
      when Hash
        error = parsed["error"]
        return false unless error.is_a?(Hash) && error["code"] == -32_603 && error.key?("data")

        error.delete("data")
        true
      else
        false
      end
    end

    # --- SDK exception reporting --------------------------------------------

    # The SDK turns tool/transport exceptions into JSON-RPC error responses and,
    # by default, reports them nowhere (its default reporter is a no-op), so
    # real bugs stay invisible to Rails' error tracking. Route them to
    # Rails.error instead. Deliberately DROP the SDK-supplied context: some of
    # its call sites pass the raw request body (`{ request: body_string }`),
    # which can contain a private paste's full content and tool arguments. Only
    # the safe, non-sensitive user id is attached.
    def report_mcp_exception(exception, _sdk_context)
      Rails.error.report(
        exception,
        handled: true,
        source: "mcp",
        context: { user_id: @current_access_token&.resource_owner_id }
      )
    end

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
      # Bump usage tracking only on the successful-auth path -- never for the
      # failure branches above (nothing to bump: no accessible token).
      bump_last_used_at!(access_token)
    end

    # Throttled usage tracking driving the nightly OauthCleanupJob's inactivity
    # window. Mirrors ApiKey#mark_used! (update_columns: no validations, no
    # callbacks) but skips the write entirely unless the existing value is
    # stale by more than LAST_USED_AT_STALE_AFTER -- nil (never used) counts as
    # stale so the very first request always records a value.
    def bump_last_used_at!(access_token)
      last_used_at = access_token.last_used_at
      return if last_used_at.present? && last_used_at > LAST_USED_AT_STALE_AFTER.ago

      access_token.update_columns(last_used_at: Time.current)
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

    # JSON-RPC/MCP method `params` must be a structured object. When a client
    # sends an array or scalar (the JSON-RPC spec allows array params in general,
    # but MCP methods take objects), the SDK indexes the non-object by a symbol
    # and surfaces a -32603 "Internal error". Answer the semantically correct
    # -32602 "Invalid params" ourselves instead, before dispatch. Only requests
    # (those carrying an `id`) get a response; a malformed notification stays a
    # no-response (the transport acks it 202).
    def reject_non_object_params!
      body = mcp_request_body
      return if body.nil? || !body.key?(:id)
      return unless body.key?(:params)

      params = body[:params]
      return if params.nil? || params.is_a?(Hash)

      render json: { jsonrpc: "2.0", id: body[:id], error: { code: -32_602, message: "Invalid params" } }
    end

    def enforce_tool_scope!
      body = mcp_request_body
      return if body.nil?
      return unless body[:method] == "tools/call"

      required = McpTools.required_scope(requested_tool_name(body))
      # Unknown/unclassifiable tool (nil) falls through so the SDK answers
      # "unknown tool"; a scope the token already holds is fine.
      return if required.nil? || token_scopes.include?(required)

      challenge_insufficient_scope
    end

    # The tool name from a tools/call body, or nil when params is missing or not
    # an object. Guards against a malformed `"params": "not-an-object"` (String)
    # -- Hash#dig would raise a TypeError on the String and 500 the request;
    # returning nil lets the transport reject the malformed call cleanly.
    def requested_tool_name(body)
      params = body[:params]
      params.is_a?(Hash) ? params[:name] : nil
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
      return unless McpTools.required_scope(requested_tool_name(body)) == McpTools::WRITE_SCOPE

      user_id = current_token_user&.id
      return if user_id.nil?

      # Mirror the Rails `rate_limit` macro's semantics (increment a per-window
      # counter, reject once it exceeds the cap) inline so the check can be
      # conditional on the parsed body. Two sequential windows, minute then day,
      # matching two stacked `rate_limit` before_actions -- the second window is
      # only touched if the first passed. In the test env the cache is a
      # null_store whose `increment` returns nil, so this is a no-op unless a
      # real counter is injected (see the controller test).
      # NOTE the write tool is identified via requested_tool_name (nil-safe),
      # not dig, for the same malformed-params reason as enforce_tool_scope!.
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
