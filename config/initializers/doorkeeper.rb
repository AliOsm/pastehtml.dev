# frozen_string_literal: true

# Doorkeeper is the OAuth 2.1-shaped authorization server for the MCP
# endpoint (see the MCP OAuth plan). It exists solely so MCP clients
# (Claude Code, Codex CLI, ...) can act as the signed-in user; every client is
# a PUBLIC client: PKCE S256 is forced and no client secret ever exists.
#
# RFC 8707 resource binding is hand-rolled on top (Doorkeeper has no native
# support): Oauth::AuthorizationsController / Oauth::TokensController require
# a single, canonical-matching `resource` parameter, and the
# custom_access_token_attributes option below persists the canonical value
# through the grant -> access token -> refresh chain.
Doorkeeper.configure do
  orm :active_record

  resource_owner_authenticator do
    Session.find_by(id: cookies.signed[Authentication::AUTH_COOKIE_NAME])&.user || begin
      # Mirror Authentication#request_authentication: successful sign-in and
      # sign-up resume ONLY via session[:return_to_after_authenticating] -- a
      # return_to query param would be silently ignored and the OAuth flow would
      # die on the dashboard. start_new_session_for already carries this key
      # across its reset_session call.
      session[:return_to_after_authenticating] = request.fullpath
      redirect_to(new_session_path)
    end
  end

  # Inherit the app's ApplicationController so the consent screen renders in
  # the app layout with its helpers, locale switching, and the Authentication
  # concern (whose require_authentication redirect makes login-resume work
  # before the resource_owner_authenticator fallback is ever reached).
  base_controller "ApplicationController"

  # Authorization code is the only first-class flow; use_refresh_token adds
  # the refresh_token grant to the token endpoint.
  grant_flows %w[authorization_code]
  use_refresh_token

  # The MCP spec (2025-11-25) requires PKCE with S256 -- clients abort if
  # "plain" is all the server advertises.
  force_pkce
  pkce_code_challenge_methods [ "S256" ]

  # Access/refresh tokens are digested at rest, matching the pht_ API keys'
  # posture -- a leaked database dump yields no usable bearer tokens.
  hash_token_secrets

  # Header-only bearer tokens. The default ALSO accepts access_token /
  # bearer_token request params, which the MCP spec forbids.
  access_token_methods :from_bearer_authorization

  # RFC 8252 §7.3: native/CLI clients (Claude Code, Codex) receive their
  # authorization code on a loopback redirect over plain http on a per-session
  # random port. Require TLS on every other redirect URI, but never on loopback
  # -- keep this in lockstep with Oauth::RegistrationsController's own scheme
  # rules (both read McpOauth::LOOPBACK_HOSTS) so a URI it accepts at
  # registration also passes Doorkeeper's RedirectUriValidator on save.
  force_ssl_in_redirect_uri do |uri|
    McpOauth::LOOPBACK_HOSTS.exclude?(uri.host.to_s.downcase)
  end

  default_scopes :"mcp:read"
  optional_scopes :"mcp:write"

  access_token_expires_in 1.hour

  # Persists the RFC 8707 `resource` indicator: PreAuthorization slices it
  # from the (already canonicalized) authorize params onto the grant, the
  # token endpoint copies it from the grant onto the access token, and the
  # refresh grant copies it from the rotated-out token onto its replacement.
  custom_access_token_attributes [ :resource ]
end
