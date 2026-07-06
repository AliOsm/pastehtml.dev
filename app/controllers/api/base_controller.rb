module Api
  class BaseController < ActionController::API
    private
      def require_valid_supplied_api_key!
        return true unless account_api_key_supplied?
        return true if account_api_key.present?

        render json: { error: "Invalid or revoked API key." }, status: :unauthorized
        false
      end

      def require_account_api_key!
        return false unless require_valid_supplied_api_key!
        return true if account_user.present?

        render json: { error: "A valid account API key is required for that operation." }, status: :unauthorized
        false
      end

      def account_user
        account_api_key&.user
      end

      def account_api_key
        return @account_api_key if defined?(@account_api_key)

        token = supplied_account_api_key_token
        @account_api_key = token.present? ? ApiKey.authenticate(token) : nil
      end

      def account_api_key_supplied?
        supplied_account_api_key_token.present?
      end

      def supplied_account_api_key_token
        request.headers["X-PasteHTML-API-Key"].presence || request.headers["X-API-Key"].presence || bearer_api_key_token.presence
      end

      def bearer_token
        request.authorization.to_s[/\ABearer\s+(.+)\z/i, 1]&.strip.presence
      end

      def mark_account_api_key_used!
        account_api_key&.mark_used!
      end

      def bearer_api_key_token
        token = bearer_token.to_s
        token if token.start_with?(ApiKey::TOKEN_PREFIX)
      end
  end
end
