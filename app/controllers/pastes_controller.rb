class PastesController < ApplicationController
  include PasteLiveUrl
  helper_method :paste_live_url

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  # Gates only the app's own UI: paste content (live/raw/show) must open in
  # any browser -- that's the product's whole promise.
  allow_browser versions: :modern, only: %i[ new create ]

  before_action :set_paste, only: %i[ show raw rendered ]

  rate_limit to: 10, within: 1.minute, only: :create,
    with: -> { redirect_to root_path, alert: t("flash.rate_limited_minute") }
  rate_limit to: 200, within: 1.day, only: :create, name: "daily",
    with: -> { redirect_to root_path, alert: t("flash.rate_limited_day") }

  def new
  end

  def create
    return redirect_to root_path, alert: t("flash.choose_file") unless upload?

    paste = Paste.from_upload(params[:file])

    if paste.save
      redirect_to paste_path(paste)
    else
      redirect_to root_path, alert: paste.errors.full_messages.to_sentence
    end
  end

  def show
    response.headers["X-Robots-Tag"] = "noindex"
  end

  # The paste's bytes, verbatim -- the canonical fetch for programmatic clients
  # (agents reading back what they published). Served as text/plain on purpose:
  # a CDN in front of the app may post-process text/html responses -- Cloudflare's
  # email obfuscation, for one, rewrites address-looking strings in transit --
  # which would corrupt the bytes. text/plain is passed through untouched, so
  # this guarantees an exact, byte-for-byte copy. nosniff (set app-wide) keeps a
  # browser from reinterpreting it as HTML. Cached by ETag revalidation, never by
  # age: pastes can be republished through the API, so caches must always recheck.
  def raw
    response.headers["X-Robots-Tag"] = "noindex"
    response.headers["Referrer-Policy"] = "no-referrer"

    if stale?(@paste, public: true)
      send_data @paste.content, type: "text/plain; charset=utf-8", disposition: :inline
    end
  end

  # Renders the paste as HTML inside an opaque origin: the CSP sandbox (without
  # allow-same-origin) keeps untrusted HTML from touching cookies, storage, or
  # anything else on this domain. The action is `rendered` because `render` is
  # reserved by ActionController; the public path is /p/<token>/render. ETag-
  # revalidated like `raw`, since pastes can be republished.
  def rendered
    response.headers["Content-Security-Policy"] = "sandbox allow-scripts allow-forms allow-popups allow-modals allow-downloads"
    response.headers["X-Robots-Tag"] = "noindex"
    response.headers["Referrer-Policy"] = "no-referrer"

    if stale?(@paste, public: true)
      send_data @paste.content, type: "text/html; charset=utf-8", disposition: :inline
    end
  end

  # Serves the paste as a real page on its own origin (<token>.pastehtml.dev).
  # No CSP sandbox here: the separate origin is the isolation, and it gives
  # documents working localStorage that no other paste (or the app) can touch.
  def live
    # Case-insensitive because browsers lowercase hostnames and pre-launch
    # tokens were mixed-case base58.
    @paste = Paste.where("LOWER(token) = ?", request.host[/\A[^.]+/]).take!
    response.headers["X-Robots-Tag"] = "noindex"
    response.headers["Referrer-Policy"] = "no-referrer"
    # The share page (a different origin) embeds this page as its preview.
    response.headers.delete("X-Frame-Options")

    if stale?(@paste, public: true)
      send_data @paste.content, type: "text/html; charset=utf-8", disposition: :inline
    end
  end

  private
    def set_paste
      @paste = Paste.find_by!(token: params[:token])
    end

    def upload?
      params[:file].respond_to?(:original_filename)
    end
end
