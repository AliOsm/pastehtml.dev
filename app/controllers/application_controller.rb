class ApplicationController < ActionController::Base
  include Authentication
  include PasteAccess
  include PasteLiveUrl
  include LocaleSwitching

  # paste_live_url builds a paste's per-origin URL and is used by shared paste
  # views (e.g. the dashboard list rendered by both PastesController#index and
  # FoldersController#show) and by PasteAccess#paste_preview_url, so it lives here.
  helper_method :paste_origin_request?, :paste_live_url

  private
    def paste_origin_request?
      labels = request.host.to_s.downcase.split(".")
      subdomainish_host = labels.length >= 3 || (labels.last == "localhost" && labels.length >= 2)

      subdomainish_host && Paste.hosted_subdomain?(labels.first)
    end
end
