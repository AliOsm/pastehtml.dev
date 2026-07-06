module Api
  # Lets agents and scripts publish without a browser:
  #
  #   curl -F "file=@plan.html" https://pastehtml.dev/api/pastes
  #   curl --data-binary @plan.html "https://pastehtml.dev/api/pastes?filename=plan.html"
  #
  # Anonymous creation reveals an `update_token` (once — only a digest is
  # stored); its holder can update the paste any number of times while it stays
  # anonymous — claiming it into an account retires the token and the account key
  # takes over. Signed-in users can also create account API keys from /api_keys.
  # When an agent sends
  # one as `Authorization: Bearer <api_key>`, new pastes are saved to that
  # user's dashboard and may be filed into a folder by key scope, folder_id, or
  # folder_name.
  class PastesController < BaseController
    include PasteLiveUrl

    RAW_BODY_MEDIA_TYPES = %w[
      text/html text/plain text/markdown text/x-markdown application/xhtml+xml application/octet-stream
    ].freeze
    PASTE_OPTION_KEYS = %i[ custom_subdomain password clear_password folder_id folder_name clear_folder ].freeze

    # Layered: the minute window absorbs bursts, the day window caps
    # sustained abuse (pastes can never be deleted, so disk only grows).
    rate_limit to: 20, within: 1.minute
    rate_limit to: 1000, within: 1.day, name: "daily"

    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "No paste with that token." }, status: :not_found
    end

    def create
      return unless require_valid_supplied_api_key!
      return render_errors([ "Provide an HTML file or a text/html request body." ]) unless content_submitted?

      filename = submitted_filename || default_filename
      paste = Paste.new(content: Paste.render_content(submitted_content, filename), original_filename: filename)
      paste.user = account_user if account_user.present?
      options_applied, saved = apply_options_and_persist(paste) { paste.save }
      return unless options_applied

      if saved
        mark_account_api_key_used!
        render json: create_payload(paste), status: :created
      else
        render_errors paste
      end
    end

    def update
      return unless require_valid_supplied_api_key!

      paste = Paste.find_by!(token: params[:token])
      authorized_by_key = paste_updatable_with_account_key?(paste)
      authorized_by_token = paste.updatable_with?(update_token)
      return render_forbidden unless authorized_by_key || authorized_by_token

      paste.user ||= account_user if account_user.present? && authorized_by_token
      return render_errors([ "Provide an HTML file, a text/html request body, or paste options to update." ]) unless content_submitted? || option_params_submitted?

      options_applied, saved = apply_options_and_persist(paste) do
        if content_submitted?
          paste.republish(content: submitted_content, original_filename: submitted_filename)
        else
          paste.save
        end
      end
      return unless options_applied

      if saved
        mark_account_api_key_used!
        render json: payload(paste)
      else
        render_errors paste
      end
    end

    private
      def upload
        params[:file].respond_to?(:original_filename) ? params[:file] : nil
      end

      def content_submitted?
        upload.present? || raw_content_submitted?
      end

      def raw_content_submitted?
        upload.blank? && raw_body.present? && (request.media_type.blank? || RAW_BODY_MEDIA_TYPES.include?(request.media_type))
      end

      def submitted_content
        upload ? Paste.read_upload(upload) : raw_content
      end

      def submitted_filename
        upload ? upload.original_filename : params[:filename].presence
      end

      # A raw body sent as text/markdown gets a .md default so it's rendered
      # (multipart uploads carry their own filename via `submitted_filename`).
      def default_filename
        markdown_request? ? "untitled.md" : "untitled.html"
      end

      def markdown_request?
        request.media_type.to_s.match?(%r{\Atext/(x-)?markdown\z})
      end

      def raw_content
        raw_body.force_encoding(Encoding::UTF_8).scrub
      end

      def raw_body
        return @raw_body if defined?(@raw_body)

        request.body.rewind if request.body.respond_to?(:rewind)
        @raw_body = request.body.read(Paste::MAX_CONTENT_BYTES + 1).to_s
      ensure
        request.body.rewind if request.body.respond_to?(:rewind)
      end

      def update_token
        request.headers["X-Update-Token"].presence || params[:update_token].presence || (account_api_key_supplied? ? nil : bearer_token)
      end

      def option_params_submitted?
        PASTE_OPTION_KEYS.any? { |key| params.key?(key) }
      end

      def paste_updatable_with_account_key?(paste)
        return false if account_api_key.blank? || !paste.owned_by?(account_user)
        return true if account_api_key.folder_id.blank?

        paste.folder_id == account_api_key.folder_id
      end


      def apply_options_and_persist(paste)
        options_applied = false
        saved = false

        Paste.transaction do
          options_applied = apply_options(paste)
          raise ActiveRecord::Rollback unless options_applied

          saved = yield
          raise ActiveRecord::Rollback unless saved
        end

        [ options_applied, saved ]
      end

      def apply_options(paste)
        options = params.slice(*PASTE_OPTION_KEYS).permit(*PASTE_OPTION_KEYS)
        paste.user ||= account_user if account_user.present?

        # Custom subdomains are a scarce, permanent, per-paste origin; require an
        # account so they can't be squatted anonymously (matches the browser UI).
        return render_subdomain_requires_api_key if options[:custom_subdomain].present? && account_api_key.blank?
        paste.custom_subdomain = options[:custom_subdomain] if options.key?(:custom_subdomain)

        if ActiveModel::Type::Boolean.new.cast(options[:clear_password])
          paste.password_digest = nil
        elsif options[:password].present?
          paste.password = options[:password]
        end

        assign_api_folder(paste, options)
      end

      def assign_api_folder(paste, options)
        folder_requested = options.key?(:folder_id) || options.key?(:folder_name) || ActiveModel::Type::Boolean.new.cast(options[:clear_folder])
        requested_folder_id = parse_folder_id(options[:folder_id])
        requested_folder_name = options[:folder_name].to_s.strip.presence
        clear_folder = ActiveModel::Type::Boolean.new.cast(options[:clear_folder])
        invalid_folder_id = options[:folder_id].present? && requested_folder_id.blank?

        if account_api_key&.folder.present?
          return render_scoped_folder_mismatch if clear_folder
          return render_folder_not_found if invalid_folder_id
          return render_scoped_folder_mismatch if requested_folder_id.present? && requested_folder_id != account_api_key.folder_id
          return render_scoped_folder_mismatch if requested_folder_name.present? && !account_api_key.folder.name.casecmp?(requested_folder_name)

          paste.folder = account_api_key.folder
          return true
        end

        return true unless folder_requested
        return render_folder_requires_api_key if account_api_key.blank?

        if clear_folder || (requested_folder_id.blank? && requested_folder_name.blank? && !invalid_folder_id)
          paste.folder = nil
          return true
        end

        if requested_folder_id.present? || invalid_folder_id
          return render_folder_not_found if invalid_folder_id

          folder = account_user.folders.find_by(id: requested_folder_id)
          return render_folder_not_found if folder.blank?

          if requested_folder_name.present? && !folder.name.casecmp?(requested_folder_name)
            return render_folder_name_mismatch
          end
        else
          folder = find_or_create_named_folder(requested_folder_name)
          return render_errors(folder) if folder.invalid?
        end

        paste.folder = folder
        true
      end

      def parse_folder_id(value)
        return if value.blank?

        # Base 10 explicitly: the default base 0 auto-detects radix, so "010"
        # would parse as octal 8 and file the paste into the wrong folder.
        Integer(value, 10, exception: false)
      end

      # Find-or-create by name, tolerant of a concurrent request creating the
      # same folder. The save runs in a savepoint so a lost race (unique-index
      # violation) rolls back only the nested insert, leaving the outer paste
      # transaction usable to reuse the winner's row instead of surfacing a 500.
      def find_or_create_named_folder(name)
        existing = account_user.folders.where("LOWER(name) = ?", name.downcase).first
        return existing if existing

        folder = account_user.folders.new(name: name)
        begin
          Folder.transaction(requires_new: true) { folder.save! }
          folder
        rescue ActiveRecord::RecordInvalid
          folder
        rescue ActiveRecord::RecordNotUnique
          account_user.folders.find_by!("LOWER(name) = ?", name.downcase)
        end
      end

      def render_errors(record_or_messages)
        messages = record_or_messages.respond_to?(:errors) ? record_or_messages.errors.full_messages : Array(record_or_messages)
        render json: { errors: messages }, status: :unprocessable_entity
        false
      end

      def render_forbidden
        render json: { error: "Invalid or missing update token, or this API key cannot access that paste." }, status: :forbidden
        false
      end

      def render_folder_requires_api_key
        render json: { error: "folder_id, folder_name, and clear_folder require an account API key." }, status: :unauthorized
        false
      end

      def render_subdomain_requires_api_key
        render json: { error: "custom_subdomain requires an account API key." }, status: :unauthorized
        false
      end

      def render_folder_not_found
        render json: { errors: [ "Folder not found for this API key." ] }, status: :unprocessable_entity
        false
      end

      def render_scoped_folder_mismatch
        render json: { errors: [ "This API key is scoped to a different folder." ] }, status: :unprocessable_entity
        false
      end

      def render_folder_name_mismatch
        render json: { errors: [ "folder_id and folder_name do not refer to the same folder." ] }, status: :unprocessable_entity
        false
      end

      def create_payload(paste)
        body = payload(paste)
        body[:update_token] = paste.update_token if account_api_key.blank?
        body
      end

      def payload(paste)
        {
          token: paste.token,
          title: paste.display_title,
          custom_subdomain: paste.custom_subdomain,
          folder: paste.folder && { id: paste.folder_id, name: paste.folder.name },
          owner: paste.user_id.present? ? { id: paste.user_id } : nil,
          account_paste: paste.user_id.present?,
          password_protected: paste.password_protected?,
          views_count: paste.views_count,
          live_url: paste_live_url(paste),
          url: paste_url(paste),
          raw_url: raw_paste_url(paste),
          render_url: render_paste_url(paste),
          markdown_url: markdown_paste_url(paste)
        }
      end
  end
end
