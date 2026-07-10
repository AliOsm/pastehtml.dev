# Doorkeeper's "authorized applications" screen, restyled as the account's
# "Connected agents" screen: every OAuth client (Claude Code, Codex, ...) the
# signed-in user has authorized for the MCP endpoint, with a one-click revoke.
# Authentication is the app's own -- ApplicationController's Authentication
# concern (see Doorkeeper's base_controller config) runs before Doorkeeper's
# own resource_owner_authenticator ever gets a chance to redirect.
class Oauth::AuthorizedApplicationsController < Doorkeeper::AuthorizedApplicationsController
  # Implicit layout lookup would otherwise stop at the gem's bundled
  # layouts/doorkeeper/application before ever reaching the app's layout --
  # see Oauth::AuthorizationsController for the same fix on the consent screen.
  layout "application"

  def index
    @applications = Doorkeeper.config.application_model
      .authorized_for(current_resource_owner)
      .order(created_at: :desc, id: :desc)

    # One query for every non-revoked token this user holds, grouped in Ruby
    # by application -- avoids an N+1 computing each application's granted
    # scopes and last-used time in the view (see Oauth::AuthorizedApplicationsHelper).
    @tokens_by_application_id = Doorkeeper::AccessToken
      .active_for(current_resource_owner)
      .group_by(&:application_id)
  end

  # Doorkeeper's stock action also serves JSON and a gem-localized flash;
  # this screen is HTML-only, so the override drops the JSON branch and uses
  # the app's own bilingual copy instead.
  def destroy
    Doorkeeper.config.application_model.revoke_tokens_and_grants_for(params[:id], current_resource_owner)
    redirect_to oauth_authorized_applications_url, status: :see_other, notice: t("connected_agents.revoked")
  end
end
