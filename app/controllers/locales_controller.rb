# Persists the visitor's language choice from the header toggle. The value is
# validated against the supported locales before it ever touches a cookie, so a
# crafted URL can't smuggle an arbitrary locale in. The choice takes effect on
# the next request, which the redirect triggers.
class LocalesController < ApplicationController
  allow_unauthenticated_access

  def update
    if I18n.available_locales.map(&:to_s).include?(params[:locale])
      cookies.permanent[LocaleSwitching::LOCALE_COOKIE_NAME] = {
        value: params[:locale],
        secure: Rails.env.production? || request.ssl?,
        same_site: :lax,
        path: "/"
      }
    end

    redirect_back fallback_location: root_path
  end
end
