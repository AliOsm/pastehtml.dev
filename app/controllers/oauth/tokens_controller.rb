# Doorkeeper's token endpoint plus mandatory RFC 8707 resource validation for
# both grant types it serves (authorization_code and refresh_token). Refresh
# grants may omit `resource` for clients whose OAuth library does not repeat
# the original resource during refresh; Doorkeeper copies the canonical value
# from the rotated-out token. Any explicitly supplied resource is still
# validated exactly -- see Oauth::AuthorizationsController.
class Oauth::TokensController < Doorkeeper::TokensController
  include Oauth::ResourceIndicatorEnforcement

  before_action :enforce_resource_indicator, only: :create

  private
    def allow_omitted_resource_indicator?
      raw_resource_parameter_omitted? && raw_parameter_values("grant_type") == [ "refresh_token" ]
    end

    # Standard OAuth token-endpoint error: 400 JSON with the RFC 8707
    # invalid_target error code.
    def reject_invalid_target
      error_response = Doorkeeper::OAuth::ErrorResponse.new(name: :invalid_target)
      headers.merge!(error_response.headers)
      render json: error_response.body, status: error_response.status
    end
end
