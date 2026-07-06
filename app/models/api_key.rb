class ApiKey < ApplicationRecord
  TOKEN_PREFIX = "pht_"
  TOKEN_LENGTH = 40
  PREFIX_LENGTH = 12
  TOKEN_FORMAT = /\A#{Regexp.escape(TOKEN_PREFIX)}[1-9A-HJ-NP-Za-km-z]{#{TOKEN_LENGTH}}\z/o

  belongs_to :user
  belongs_to :folder, optional: true

  attr_reader :plain_key

  normalizes :name, with: ->(name) { name.to_s.strip }

  validates :name, presence: true, length: { maximum: 80 }
  validates :key_digest, presence: true, uniqueness: true
  validates :key_prefix, presence: true, length: { maximum: PREFIX_LENGTH }
  validate :folder_must_belong_to_user

  before_validation :generate_plain_key, on: :create

  scope :active, -> { where(revoked_at: nil) }
  scope :recent, -> { order(created_at: :desc, id: :desc) }

  class << self
    def generate_key
      "#{TOKEN_PREFIX}#{SecureRandom.base58(TOKEN_LENGTH)}"
    end

    def digest(raw_key)
      secret = Rails.application.secret_key_base || "pastehtml-dev"
      OpenSSL::HMAC.hexdigest("SHA256", secret, raw_key.to_s)
    end

    def authenticate(raw_key)
      value = raw_key.to_s.strip
      return if value.blank? || !value.match?(TOKEN_FORMAT)

      active.find_by(key_digest: digest(value))
    end
  end

  def active?
    revoked_at.blank?
  end

  def revoked?
    revoked_at.present?
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def mark_used!
    update_columns(last_used_at: Time.current, updated_at: Time.current)
  end

  def display_prefix
    "#{key_prefix}…"
  end

  private
    def generate_plain_key
      return if key_digest.present?

      loop do
        @plain_key = self.class.generate_key
        self.key_prefix = @plain_key.first(PREFIX_LENGTH)
        self.key_digest = self.class.digest(@plain_key)
        break unless self.class.exists?(key_digest:)
      end
    end

    def folder_must_belong_to_user
      return if folder.blank? && folder_id.blank?

      if user.blank?
        errors.add(:folder, :requires_user)
      elsif folder&.user_id != user_id
        errors.add(:folder, :invalid)
      end
    end
end
