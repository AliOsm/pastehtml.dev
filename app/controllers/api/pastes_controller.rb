module Api
  # Lets agents and scripts publish without a browser:
  #
  #   curl -F "file=@plan.html" https://pastehtml.dev/api/pastes
  #   curl --data-binary @plan.html "https://pastehtml.dev/api/pastes?filename=plan.html"
  #
  # Creation reveals an `update_token` (once — only a digest is stored); its
  # holder can update the paste any number of times:
  #
  #   curl -X PATCH -H "Authorization: Bearer <update_token>" \
  #     -F "file=@plan.html" https://pastehtml.dev/api/pastes/<token>
  class PastesController < ActionController::API
    include PasteLiveUrl

    # Layered: the minute window absorbs bursts, the day window caps
    # sustained abuse (pastes can never be deleted, so disk only grows).
    rate_limit to: 20, within: 1.minute
    rate_limit to: 1000, within: 1.day, name: "daily"

    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "No paste with that token." }, status: :not_found
    end

    def create
      paste = Paste.new(content: submitted_content, original_filename: submitted_filename || "untitled.html")

      if paste.save
        render json: payload(paste).merge(update_token: paste.update_token), status: :created
      else
        render_errors paste
      end
    end

    def update
      paste = Paste.find_by!(token: params[:token])
      return render_forbidden unless paste.updatable_with?(update_token)

      if paste.republish(content: submitted_content, original_filename: submitted_filename)
        render json: payload(paste)
      else
        render_errors paste
      end
    end

    private
      def upload
        params[:file].respond_to?(:original_filename) ? params[:file] : nil
      end

      def submitted_content
        upload ? Paste.read_upload(upload) : raw_content
      end

      def submitted_filename
        upload ? upload.original_filename : params[:filename].presence
      end

      def raw_content
        request.raw_post.to_s.byteslice(0, Paste::MAX_CONTENT_BYTES + 1).force_encoding(Encoding::UTF_8).scrub
      end

      def update_token
        request.authorization.to_s[/\ABearer (.+)\z/, 1] || params[:update_token].presence
      end

      def render_errors(paste)
        render json: { errors: paste.errors.full_messages }, status: :unprocessable_entity
      end

      def render_forbidden
        render json: { error: "Invalid or missing update token." }, status: :forbidden
      end

      def payload(paste)
        {
          token: paste.token,
          title: paste.display_title,
          live_url: paste_live_url(paste),
          url: paste_url(paste),
          raw_url: raw_paste_url(paste)
        }
      end
  end
end
