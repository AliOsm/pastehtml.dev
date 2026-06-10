class PastesController < ApplicationController
  include PasteLiveUrl
  helper_method :paste_live_url

  before_action :set_paste, only: %i[ show raw ]

  rate_limit to: 10, within: 1.minute, only: :create,
    with: -> { redirect_to root_path, alert: "Whoa, slow down! You can publish again in a minute." }

  def new
  end

  def create
    return redirect_to root_path, alert: "Choose an HTML file to upload." unless upload?

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

  # Serves the paste verbatim inside an opaque origin: the CSP sandbox (without
  # allow-same-origin) keeps untrusted HTML from touching cookies, storage, or
  # anything else on this domain. Cached by ETag revalidation, never by age:
  # pastes can be republished through the API, so caches must always recheck.
  def raw
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
