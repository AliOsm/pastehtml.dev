# Rails authentication-generator style session handling, with app-specific
# helpers for the dashboard and paste ownership checks.
module Authentication
  extend ActiveSupport::Concern

  # Keep the persistent login pointer host-only in production. Paste documents
  # run on user-controlled subdomains, so a generic cookie name could be
  # shadowed by a Domain=.pastehtml.dev cookie tossed from a paste origin. The
  # __Host- prefix makes browsers reject Domain-scoped variants.
  AUTH_COOKIE_NAME = Rails.env.production? ? "__Host-pastehtml_session_id" : "pastehtml_session_id"

  # Cap the post-login return path stored in the (cookie) session. The whole
  # session must fit in ~4 KB, so this is sized to hold an OAuth authorize path
  # built from a max-length accepted redirect_uri
  # (Oauth::RegistrationsController::MAX_REDIRECT_URI_LENGTH) plus a normal state
  # and the fixed params -- so any client accepted at registration can resume
  # login -- while staying comfortably within the cookie budget. A path above
  # this (e.g. a pathologically large `state`) is skipped rather than stored, so
  # sign-in still works (resume falls back to the default landing page) instead
  # of raising CookieOverflow and 500ing.
  MAX_RETURN_TO_BYTES = 2000

  included do
    before_action :require_authentication
    helper_method :authenticated?, :current_user
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session.present?
    end

    def current_user
      resume_session&.user
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    def find_session_by_cookie
      Session.find_by(id: cookies.signed[AUTH_COOKIE_NAME]) if cookies.signed[AUTH_COOKIE_NAME]
    end

    def request_authentication
      if request.get? && request.fullpath.bytesize <= MAX_RETURN_TO_BYTES
        session[:return_to_after_authenticating] = request.fullpath
      end
      # 303 so an unauthenticated PATCH/DELETE (folders, api keys, sign-out, owned
      # paste updates) follows to sign-in as a GET instead of replaying the verb
      # against the GET-only /session/new.
      redirect_to new_session_path, status: :see_other, alert: t("authentication.required")
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || pastes_url
    end

    def start_new_session_for(user)
      return_to_after_authenticating = session[:return_to_after_authenticating]
      reset_session
      session[:return_to_after_authenticating] = return_to_after_authenticating if return_to_after_authenticating.present?

      user.sessions.create!(user_agent: request.user_agent.to_s.truncate(255), ip_address: request.remote_ip).tap do |session|
        Current.session = session
        cookies.signed.permanent[AUTH_COOKIE_NAME] = {
          value: session.id,
          httponly: true,
          same_site: :lax,
          secure: Rails.env.production? || request.ssl?,
          path: "/"
        }
      end
    end

    def terminate_session
      Current.session&.destroy
      Current.session = nil
      cookies.delete(AUTH_COOKIE_NAME, secure: Rails.env.production? || request.ssl?, path: "/")
    end
end
