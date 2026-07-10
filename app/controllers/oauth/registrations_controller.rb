# RFC 7591 Dynamic Client Registration -- POST /oauth/register. This is the
# PUBLIC, internet-facing endpoint where MCP agents (Claude Code, Codex CLI,
# ...) self-register before running the OAuth flow, so client metadata is
# validated strictly rather than echoed. Unknown fields are silently ignored
# per RFC 7591; unrecognized values are rejected.
#
# ActionController::API on purpose, not ApplicationController: that base
# includes the Authentication concern, whose default before_action would
# redirect this session-less endpoint to the login page, and CLI clients POST
# bare JSON with no CSRF token. Every client minted here is a PUBLIC client
# (confidential: false) that never holds a secret -- Doorkeeper skips secret
# generation because the `secret` column is nullable and the client is public.
class Oauth::RegistrationsController < ActionController::API
  # Signals a rejected registration; carried up to a single 400 JSON renderer.
  class InvalidRegistration < StandardError
    attr_reader :code

    def initialize(code, description)
      @code = code
      super(description)
    end
  end

  ALLOWED_GRANT_TYPES = %w[authorization_code refresh_token].freeze
  ALLOWED_RESPONSE_TYPES = %w[code].freeze
  ALLOWED_SCOPES = %w[mcp:read mcp:write].freeze
  # Regardless of the requested subset, applications are persisted with -- and
  # the response returns -- the full allowed set. The granted subset lives
  # per-authorization, so a later step-up never needs a second registration.
  NORMALIZED_SCOPE = ALLOWED_SCOPES.join(" ").freeze
  MAX_REDIRECT_URIS = 10
  MAX_CLIENT_NAME_LENGTH = 255
  DEFAULT_CLIENT_NAME = "Dynamically registered client"

  before_action :set_cache_headers
  before_action :reject_when_registration_disabled

  # Public, unauthenticated endpoint -- cap per-IP registration churn (Claude
  # Code is known to re-register aggressively). Mirrors the app's other
  # solid_cache-backed rate limits; the 429 body is JSON for this API surface.
  rate_limit to: 10, within: 1.hour,
    with: -> { render_error(:too_many_requests, "too_many_requests", "Too many registration requests. Try again later.") }

  rescue_from InvalidRegistration do |error|
    render_error(:bad_request, error.code, error.message)
  end

  def create
    redirect_uris = validated_redirect_uris
    validate_token_endpoint_auth_method!
    grant_types = validated_grant_types
    response_types = validated_response_types
    validate_scope!
    client_name = validated_client_name

    application = Doorkeeper::Application.create!(
      name: client_name || DEFAULT_CLIENT_NAME,
      redirect_uri: redirect_uris.join("\n"),
      scopes: NORMALIZED_SCOPE,
      confidential: false,
      dynamic: true
    )

    render json: registration_response(application, redirect_uris, grant_types, response_types), status: :created
  end

  private
    def registration_response(application, redirect_uris, grant_types, response_types)
      {
        client_id: application.uid,
        client_id_issued_at: application.created_at.to_i,
        client_name: application.name,
        redirect_uris: redirect_uris,
        grant_types: grant_types,
        response_types: response_types,
        scope: NORMALIZED_SCOPE,
        # RFC 7591's omitted default is client_secret_basic, which contradicts
        # these secretless public clients -- so state "none" explicitly.
        token_endpoint_auth_method: "none"
      }
    end

    def validated_redirect_uris
      uris = client_metadata["redirect_uris"]
      unless uris.is_a?(Array) && uris.any?
        raise invalid_redirect_uri("redirect_uris is required and must be a non-empty array.")
      end
      if uris.length > MAX_REDIRECT_URIS
        raise invalid_redirect_uri("At most #{MAX_REDIRECT_URIS} redirect_uris are allowed.")
      end

      uris.each { |uri| validate_redirect_uri!(uri) }
      raise invalid_redirect_uri("redirect_uris must not contain duplicates.") if uris.uniq.length != uris.length

      uris
    end

    def validate_redirect_uri!(value)
      raise invalid_redirect_uri("Each redirect_uri must be a string.") unless value.is_a?(String)

      uri = URI.parse(value)
      raise invalid_redirect_uri("redirect_uri must be an absolute URI: #{value}") unless uri.absolute?
      raise invalid_redirect_uri("redirect_uri must not contain a fragment: #{value}") unless uri.fragment.nil?
      raise invalid_redirect_uri("redirect_uri must not contain userinfo: #{value}") unless uri.userinfo.nil?

      scheme = uri.scheme.to_s.downcase
      host = uri.host.to_s.downcase
      raise invalid_redirect_uri("redirect_uri is missing a host: #{value}") if host.blank?

      validate_redirect_scheme!(scheme, host, value)
    rescue URI::InvalidURIError
      raise invalid_redirect_uri("redirect_uri is not a valid URI: #{value}")
    end

    # https is allowed for any host (exact-match at authorize time); http only
    # for RFC 8252 loopback hosts, on any port. Everything else is rejected.
    def validate_redirect_scheme!(scheme, host, value)
      case scheme
      when "https"
        nil
      when "http"
        return if McpOauth::LOOPBACK_HOSTS.include?(host)

        raise invalid_redirect_uri("http redirect_uris are only allowed for loopback hosts: #{value}")
      else
        raise invalid_redirect_uri("redirect_uri must use https (or http for loopback): #{value}")
      end
    end

    def validate_token_endpoint_auth_method!
      method = client_metadata["token_endpoint_auth_method"]
      return if method.nil? || method == "none"

      raise invalid_client_metadata(%(token_endpoint_auth_method must be "none".))
    end

    def validated_grant_types
      requested = client_metadata["grant_types"]
      return ALLOWED_GRANT_TYPES if requested.nil?

      unless requested.is_a?(Array) && requested.any? && (requested - ALLOWED_GRANT_TYPES).empty?
        raise invalid_client_metadata("grant_types must be a non-empty subset of #{ALLOWED_GRANT_TYPES.join(", ")}.")
      end

      ALLOWED_GRANT_TYPES
    end

    def validated_response_types
      requested = client_metadata["response_types"]
      return ALLOWED_RESPONSE_TYPES if requested.nil?

      unless requested.is_a?(Array) && requested.any? && (requested - ALLOWED_RESPONSE_TYPES).empty?
        raise invalid_client_metadata(%(response_types must be ["code"].))
      end

      ALLOWED_RESPONSE_TYPES
    end

    def validate_scope!
      scope = client_metadata["scope"]
      return if scope.nil?

      raise invalid_client_metadata("scope must be a space-delimited string.") unless scope.is_a?(String)
      return if (scope.split - ALLOWED_SCOPES).empty?

      raise invalid_client_metadata("scope may only request #{ALLOWED_SCOPES.join(" and ")}.")
    end

    def validated_client_name
      name = client_metadata["client_name"]
      return if name.nil?

      raise invalid_client_metadata("client_name must be a string.") unless name.is_a?(String)

      stripped = name.strip
      if stripped.length > MAX_CLIENT_NAME_LENGTH
        raise invalid_client_metadata("client_name must be at most #{MAX_CLIENT_NAME_LENGTH} characters.")
      end

      stripped.presence
    end

    # The parsed JSON request body. Read straight from request_parameters so
    # unknown fields are naturally ignored and query-string params can't sneak
    # in as metadata. A non-object body yields no redirect_uris and is rejected.
    def client_metadata
      body = request.request_parameters
      body.is_a?(Hash) ? body : {}
    end

    def invalid_redirect_uri(description)
      InvalidRegistration.new("invalid_redirect_uri", description)
    end

    def invalid_client_metadata(description)
      InvalidRegistration.new("invalid_client_metadata", description)
    end

    def reject_when_registration_disabled
      return unless ActiveModel::Type::Boolean.new.cast(ENV["MCP_DYNAMIC_REGISTRATION_DISABLED"])

      render_error(:forbidden, "registration_disabled", "Dynamic client registration is currently disabled.")
    end

    def set_cache_headers
      response.headers["Cache-Control"] = "no-store"
      response.headers["Pragma"] = "no-cache"
    end

    def render_error(status, code, description)
      render json: { error: code, error_description: description }, status: status
    end
end
