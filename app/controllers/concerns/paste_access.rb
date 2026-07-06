module PasteAccess
  extend ActiveSupport::Concern

  included do
    helper_method :paste_unlocked?, :paste_preview_url
  end

  private
    def paste_unlocked?(paste)
      return true unless paste.password_protected?
      return true if paste.owned_by?(current_user)
      return true if valid_paste_access_token?(paste)

      session_paste_unlocked?(paste)
    end

    def require_paste_password!(paste, redirect: true)
      return true if paste_unlocked?(paste)

      if redirect
        redirect_to paste_password_path(paste), alert: t("paste_passwords.required")
      else
        @paste_password_form_url = request.path
        flash.now[:alert] = t("paste_passwords.required")
        render "paste_passwords/new", status: :unauthorized
      end
      false
    end

    def unlock_paste!(paste)
      unlocks = unlocked_paste_accesses.reject { |entry| entry[:paste_id] == paste.id }
      unlocks << { paste_id: paste.id, version: paste_access_version(paste) }

      session[:unlocked_pastes] = unlocks.last(100).map do |entry|
        { "paste_id" => entry[:paste_id], "version" => entry[:version] }
      end
      session.delete(:unlocked_paste_ids)
    end

    def session_paste_unlocked?(paste)
      unlocked_paste_accesses.any? do |entry|
        entry[:paste_id] == paste.id && entry[:version] == paste_access_version(paste)
      end
    end

    def unlocked_paste_accesses
      Array(session[:unlocked_pastes]).filter_map do |entry|
        next unless entry.respond_to?(:[])

        paste_id = Integer(entry["paste_id"] || entry[:paste_id], exception: false)
        version = (entry["version"] || entry[:version]).to_s.presence
        { paste_id:, version: } if paste_id.present? && version.present?
      end
    end

    def paste_preview_url(paste)
      return paste_live_url(paste) unless paste.password_protected? && paste_unlocked?(paste)

      paste_live_url(paste, paste_access_token: paste_access_token(paste))
    end

    def paste_access_token(paste)
      paste_access_verifier.generate(
        { paste_id: paste.id, updated_at: paste_access_version(paste) },
        expires_in: 10.minutes,
        purpose: :paste_access
      )
    end

    def valid_paste_access_token?(paste)
      token = params[:paste_access_token].presence
      return false if token.blank?

      payload = paste_access_verifier.verified(token, purpose: :paste_access)
      payload = payload.with_indifferent_access if payload.present?
      payload.present? &&
        payload[:paste_id].to_i == paste.id &&
        payload[:updated_at].to_s == paste_access_version(paste)
    end

    def paste_access_version(paste)
      paste.updated_at.utc.iso8601(6)
    end

    def paste_access_verifier
      Rails.application.message_verifier(:paste_access)
    end
end
