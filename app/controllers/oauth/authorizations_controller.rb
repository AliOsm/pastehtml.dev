# Doorkeeper's authorization endpoint plus mandatory RFC 8707 resource
# binding (wired up in config/routes.rb through use_doorkeeper's controllers
# mapping). Authentication comes first: the ApplicationController base (see
# Doorkeeper's base_controller config) redirects signed-out users to sign-in
# and resumes the full authorize URL afterwards, so resource validation only
# ever runs for signed-in users.
class Oauth::AuthorizationsController < Doorkeeper::AuthorizationsController
  include Oauth::ResourceIndicatorEnforcement

  # Implicit layout lookup would otherwise stop at the gem's bundled
  # layouts/doorkeeper/application before ever reaching the app's layout.
  layout "application"

  before_action :enforce_resource_indicator, only: %i[new create]

  private
    # Feeds Doorkeeper's PreAuthorization the CANONICAL resource spelling in
    # place of the client's (already validated, case-insensitively equal)
    # value, so the grant -- and every token derived from it -- stores exactly
    # McpOauth::CONFIG[:resource_uri] and the /mcp audience check can compare
    # byte-exactly.
    def pre_auth_params
      super.merge(resource: McpOauth::CONFIG[:resource_uri])
    end

    # Doorkeeper's convention for non-redirectable authorization errors
    # (handle_auth_errors :render, the default): render the error page.
    def reject_invalid_target
      error_response = Doorkeeper::OAuth::ErrorResponse.new(name: :invalid_target, state: params[:state])
      render :error, locals: { error_response: error_response }, status: error_response.status
    end
end
