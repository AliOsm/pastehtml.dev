# Be sure to restart your server when you modify this file.
#
# Canonical, trusted configuration for the MCP OAuth authorization/resource
# server. This is intentionally boot-time and env-aware -- NEVER derive these
# values from request headers (Host, X-Forwarded-*, etc.), since that would
# let an attacker forge the issuer/resource identity used in token audience
# checks (RFC 8707) and discovery documents.
#
# Routes (host constraints), the MCP transport (allowed_hosts), discovery
# JSON documents, and audience validation all read from McpOauth::CONFIG, so
# its shape is load-bearing -- don't change the keys without updating those.
module McpOauth
  default_issuer =
    case Rails.env
    when "production"
      "https://pastehtml.dev"
    when "test"
      # Matches Rails' integration-test default host so route constraints
      # keyed on CONFIG[:host] work in tests.
      "http://www.example.com"
    else
      "http://localhost:3000"
    end

  issuer = (ENV["MCP_OAUTH_ISSUER"].presence || default_issuer).freeze

  default_host = URI(issuer).host

  host = (ENV["MCP_OAUTH_HOST"].presence || default_host).freeze

  CONFIG = {
    issuer: issuer,
    resource_uri: "#{issuer}/mcp".freeze,
    host: host,
    protected_resource_metadata_url: "#{issuer}/.well-known/oauth-protected-resource".freeze
  }.freeze

  # Loopback hosts for which RFC 8252 §7.3 permits plain-http redirect URIs on
  # any port -- native/CLI agents (Claude Code, Codex) receive their
  # authorization code on a random loopback port per session. Shared by the
  # Dynamic Client Registration validation (Oauth::RegistrationsController) and
  # Doorkeeper's redirect-URI SSL enforcement (force_ssl_in_redirect_uri), which
  # must agree on exactly which hosts skip the TLS requirement. Compared against
  # a downcased URI host, so `URI.parse("http://[::1]:...").host` -> "[::1]".
  LOOPBACK_HOSTS = %w[localhost 127.0.0.1 [::1]].freeze
end
