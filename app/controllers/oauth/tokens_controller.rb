# Doorkeeper's token endpoint plus mandatory RFC 8707 resource validation for
# both grant types it serves (authorization_code and refresh_token). No
# canonicalization is needed here: the access token's `resource` is copied
# from the grant (or from the rotated-out token on refresh), which already
# stores the canonical value -- see Oauth::AuthorizationsController.
class Oauth::TokensController < Doorkeeper::TokensController
  include Oauth::ResourceIndicatorEnforcement

  before_action :enforce_resource_indicator, only: :create

  private
    # Standard OAuth token-endpoint error: 400 JSON with the RFC 8707
    # invalid_target error code.
    def reject_invalid_target
      error_response = Doorkeeper::OAuth::ErrorResponse.new(name: :invalid_target)
      headers.merge!(error_response.headers)
      render json: error_response.body, status: error_response.status
    end
end
