# Resolves the request locale and wraps the action in it. Preference order:
# an explicit cookie (set by the header toggle) wins; otherwise we honor the
# browser's Accept-Language; otherwise English. The matching RTL/LTR direction
# is derived in the view layer (ApplicationHelper#text_direction).
module LocaleSwitching
  extend ActiveSupport::Concern

  # Host-only in production so untrusted paste subdomains can't shadow the app's
  # locale with a Domain=.pastehtml.dev cookie (the __Host- prefix makes browsers
  # reject Domain-scoped variants), mirroring the auth cookie's hardening.
  LOCALE_COOKIE_NAME = Rails.env.production? ? "__Host-locale" : "locale"

  included do
    around_action :switch_locale
  end

  private
    def switch_locale(&action)
      I18n.with_locale(resolved_locale, &action)
    end

    def resolved_locale
      locale_from_cookie || locale_from_header || I18n.default_locale
    end

    def locale_from_cookie
      # Fall back to the legacy unprefixed cookie so a saved preference survives
      # the one-time rename to __Host-locale in production (same name in dev).
      available(cookies[LOCALE_COOKIE_NAME]) || available(cookies[:locale])
    end

    # Reads the ordered language tags from Accept-Language and returns the first
    # one we actually support, so "fr,ar;q=0.8" picks Arabic over an unsupported
    # French. Quality values only affect order, which the header already encodes.
    def locale_from_header
      request.get_header("HTTP_ACCEPT_LANGUAGE").to_s.scan(/[a-z]{2}/i)
        .lazy.filter_map { |tag| available(tag) }.first
    end

    def available(tag)
      locale = tag.to_s.downcase.to_sym
      locale if I18n.available_locales.include?(locale)
    end
end
