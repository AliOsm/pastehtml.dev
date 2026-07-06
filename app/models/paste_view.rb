class PasteView < ApplicationRecord
  SOURCES = %w[show live raw render].freeze

  belongs_to :paste, counter_cache: :views_count
  belongs_to :user, optional: true

  validates :source, inclusion: { in: SOURCES }

  class << self
    def record!(paste:, request:, source:, user: nil)
      create!(
        paste:,
        user:,
        source:,
        ip_address_digest: digest_ip(request.remote_ip),
        user_agent: request.user_agent.to_s.truncate(512),
        referrer: request.referrer.to_s.truncate(2048)
      )
    rescue ActiveRecord::ActiveRecordError
      nil
    end

    private
      def digest_ip(ip_address)
        return if ip_address.blank?

        secret = Rails.application.secret_key_base || "pastehtml-dev"
        OpenSSL::HMAC.hexdigest("SHA256", secret, ip_address.to_s)
      end
  end
end
