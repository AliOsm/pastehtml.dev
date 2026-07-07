class PastesController < ApplicationController
  PASTE_OPTION_KEYS = %i[ custom_subdomain folder_id password remove_password ].freeze

  allow_unauthenticated_access only: %i[ new create show raw rendered markdown live ]

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  # Gates only the app's own UI: paste content (live/raw/show) must open in
  # any browser -- that's the product's whole promise.
  allow_browser versions: :modern, only: %i[ new create index edit update ]

  before_action :set_paste, only: %i[ show raw rendered markdown edit update ]
  before_action :require_owner!, only: %i[ edit update ]
  after_action :track_pending_view

  rate_limit to: 10, within: 1.minute, only: :create,
    with: -> { redirect_to root_path, alert: t("flash.rate_limited_minute") }
  rate_limit to: 200, within: 1.day, only: :create, name: "daily",
    with: -> { redirect_to root_path, alert: t("flash.rate_limited_day") }
  # Republishing re-renders content (Markdown/Rouge/title extraction); cap it
  # per user so a single session can't script unbounded updates.
  rate_limit to: 30, within: 1.minute, only: :update, name: "update", by: -> { Current.user&.id },
    with: -> { redirect_to paste_path(params[:token]), status: :see_other, alert: t("flash.rate_limited") }

  def index
    @folders = Current.user.folders.order(:name)
    @folder_counts = Current.user.pastes.group(:folder_id).count
    @folder = Current.user.folders.find_by(id: params[:folder_id]) if params[:folder_id].present?
    @pastes = Current.user.pastes.with_content_size.includes(:folder).recent
    @pastes = @pastes.where(folder: @folder) if @folder.present?
  end

  def new
    @paste = Paste.new
    @folders = authenticated? ? Current.user.folders.order(:name) : Folder.none
  end

  def create
    return redirect_to root_path, status: :see_other, alert: t("flash.choose_file") unless upload?

    paste = Paste.from_upload(upload)
    apply_paste_options(paste)

    if paste.save
      redirect_to paste_path(paste), status: :see_other, notice: signed_in_notice(paste)
    else
      # Re-render in place so a signed-in publisher keeps their typed options
      # (subdomain, folder, ...) instead of being bounced to a fresh home page.
      @folders = authenticated? ? Current.user.folders.order(:name) : Folder.none
      flash.now[:alert] = paste.errors.full_messages.to_sentence
      render :new, status: :unprocessable_entity
    end
  end

  def show
    response.headers["X-Robots-Tag"] = "noindex"
    return unless require_paste_password!(@paste)

    @track_view_source = "show"
  end

  # The paste's bytes, verbatim -- the canonical fetch for programmatic clients
  # (agents reading back what they published). Served as text/plain on purpose:
  # a CDN in front of the app may post-process text/html responses -- Cloudflare's
  # email obfuscation, for one, rewrites address-looking strings in transit --
  # which would corrupt the bytes. text/plain is passed through untouched, so
  # this guarantees an exact, byte-for-byte copy. nosniff (set app-wide) keeps a
  # browser from reinterpreting it as HTML. Cached by ETag revalidation, never by
  # age: pastes can be republished through the API or owner dashboard, so caches
  # must always recheck.
  def raw
    response.headers["X-Robots-Tag"] = "noindex"
    response.headers["Referrer-Policy"] = "no-referrer"
    return unless require_paste_password!(@paste)

    if stale?(@paste, public: !@paste.password_protected?)
      track_view("raw")
      send_data @paste.content, type: "text/plain; charset=utf-8", disposition: :inline
    end
  end

  # The paste converted to Markdown -- a convenience, best-effort view for
  # readers who want the prose without the markup. Served inline as text/markdown
  # (nosniff keeps a browser from reinterpreting it). Unlike `raw`, this is a
  # derived, lossy representation, not the canonical bytes; ETag-revalidated the
  # same way, since republishing a paste changes its Markdown too.
  def markdown
    response.headers["X-Robots-Tag"] = "noindex"
    response.headers["Referrer-Policy"] = "no-referrer"
    return unless require_paste_password!(@paste)

    if stale?(@paste, public: !@paste.password_protected?)
      send_data @paste.to_markdown, type: "text/markdown; charset=utf-8", disposition: :inline
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
    return unless require_paste_password!(@paste)

    if stale?(@paste, public: !@paste.password_protected?)
      track_view("render")
      send_data @paste.content, type: "text/html; charset=utf-8", disposition: :inline
    end
  end

  # Serves the paste as a real page on its own origin (<token>.pastehtml.dev or
  # a user-chosen custom subdomain). No CSP sandbox here: the separate origin is
  # the isolation, and it gives documents working localStorage that no other
  # paste (or the app) can touch.
  def live
    @paste = Paste.find_by_subdomain!(request.host[/\A[^.]+/].to_s.downcase)
    response.headers["X-Robots-Tag"] = "noindex"
    response.headers["Referrer-Policy"] = "no-referrer"
    # The share page (a different origin) embeds this page as its preview.
    response.headers.delete("X-Frame-Options")
    return unless require_paste_password!(@paste, redirect: false)

    if stale?(@paste, public: !@paste.password_protected?)
      track_view("live")
      send_data @paste.content, type: "text/html; charset=utf-8", disposition: :inline
    end
  end

  def edit
    @folders = Current.user.folders.order(:name)
  end

  def update
    replace_file(@paste) if upload?
    apply_paste_options(@paste)

    if @paste.save
      redirect_to paste_path(@paste), status: :see_other, notice: t("pastes.updated")
    else
      @folders = Current.user.folders.order(:name)
      render :edit, status: :unprocessable_entity
    end
  end

  private
    # Resolve by token or custom subdomain, so a paste that has a custom subdomain
    # is reachable at both /p/<token> and the memorable /p/<custom-subdomain>.
    def set_paste
      @paste = Paste.find_by_subdomain!(params[:token])
    end

    def require_owner!
      return if @paste.owned_by?(Current.user)

      redirect_to paste_path(@paste), status: :see_other, alert: t("pastes.not_owner")
    end

    def upload
      params[:file]
    end

    def upload?
      upload.respond_to?(:original_filename)
    end

    def replace_file(paste)
      paste.original_filename = upload.original_filename
      paste.content = Paste.render_content(Paste.read_upload(upload), paste.original_filename)
    end

    def apply_paste_options(paste)
      return unless authenticated?

      paste.user ||= Current.user
      options = params.slice(*PASTE_OPTION_KEYS).permit(*PASTE_OPTION_KEYS)
      paste.custom_subdomain = options[:custom_subdomain] if options.key?(:custom_subdomain)
      assign_folder(paste, options[:folder_id]) if options.key?(:folder_id)

      if ActiveModel::Type::Boolean.new.cast(options[:remove_password])
        paste.password_digest = nil
      elsif options[:password].present?
        paste.password = options[:password]
      end
    end

    # Only reached from apply_paste_options, which returns early unless
    # authenticated?, so Current.user is guaranteed present here.
    def assign_folder(paste, folder_id)
      if folder_id.blank?
        paste.folder = nil
      else
        paste.folder = Current.user.folders.find_by(id: folder_id)
        # Keep an unowned/unknown id so folder_must_belong_to_user can reject it.
        paste.folder_id = folder_id if paste.folder.nil?
      end
    end

    def signed_in_notice(paste)
      return t("pastes.created") if paste.user_id.present?

      t("pastes.created_anonymous")
    end

    def track_view(source)
      PasteView.record!(paste: @paste, request:, source:, user: current_user)
    end

    def track_pending_view
      track_view(@track_view_source) if @track_view_source.present? && response.status == 200
    end
end
