class User < ApplicationRecord
  MAX_PASSWORD_BYTES = 72

  has_secure_password

  has_many :sessions, dependent: :destroy
  has_many :folders, dependent: :destroy
  has_many :api_keys, dependent: :destroy
  has_many :pastes, dependent: :nullify
  has_many :paste_views, dependent: :nullify

  normalizes :email_address, with: ->(email_address) { email_address.to_s.strip.downcase }

  validates :email_address, presence: true,
    length: { maximum: 255 },
    format: { with: URI::MailTo::EMAIL_REGEXP },
    uniqueness: { case_sensitive: false }
  validates :password, length: { minimum: 8 }, allow_nil: true
  validate :password_must_fit_bcrypt_limit

  def password=(unencrypted_password)
    @password = unencrypted_password
    super if unencrypted_password.nil? || unencrypted_password.to_s.bytesize <= MAX_PASSWORD_BYTES
  end

  private
    def password_must_fit_bcrypt_limit
      return if password.nil? || password.bytesize <= MAX_PASSWORD_BYTES

      errors.add(:password, :too_long, count: MAX_PASSWORD_BYTES)
    end
end
