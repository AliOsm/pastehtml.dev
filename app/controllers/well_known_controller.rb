# OAuth discovery documents for the MCP authorization/resource server:
# RFC 9728 (protected resource metadata) and RFC 8414 (authorization server
# metadata). Both are static JSON built exclusively from McpOauth::CONFIG --
# never from request headers, since that's the trusted issuer/resource
# identity used in audience checks (see config/initializers/mcp_oauth.rb).
#
# ActionController::API on purpose, not ApplicationController: that base
# includes the Authentication concern, whose default before_action would
# redirect these public, session-less endpoints to the login page. MCP
# clients probe them before any login has happened.
class WellKnownController < ActionController::API
  SCOPES_SUPPORTED = %w[mcp:read mcp:write].freeze

  # RFC 9728 -- GET /.well-known/oauth-protected-resource(/mcp)
  def protected_resource
    render json: {
      resource: McpOauth::CONFIG[:resource_uri],
      authorization_servers: [ McpOauth::CONFIG[:issuer] ],
      scopes_supported: SCOPES_SUPPORTED,
      bearer_methods_supported: %w[header]
    }
  end

  # RFC 8414 -- GET /.well-known/oauth-authorization-server
  def authorization_server
    issuer = McpOauth::CONFIG[:issuer]

    render json: {
      issuer: issuer,
      authorization_endpoint: "#{issuer}/oauth/authorize",
      token_endpoint: "#{issuer}/oauth/token",
      registration_endpoint: "#{issuer}/oauth/register",
      revocation_endpoint: "#{issuer}/oauth/revoke",
      grant_types_supported: %w[authorization_code refresh_token],
      response_types_supported: %w[code],
      # Mandatory per RFC 8414 / the MCP spec: clients abort discovery
      # entirely if this field is missing.
      code_challenge_methods_supported: %w[S256],
      token_endpoint_auth_methods_supported: %w[none],
      scopes_supported: SCOPES_SUPPORTED
    }
  end
end
