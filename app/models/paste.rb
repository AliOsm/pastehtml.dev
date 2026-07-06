class Paste < ApplicationRecord
  TOKEN_LENGTH = 32
  # Lowercase-only because tokens double as subdomains and browsers lowercase
  # hostnames. 36^32 is still ~165 bits of entropy.
  TOKEN_ALPHABET = [ *"a".."z", *"0".."9" ].freeze
  MAX_CONTENT_BYTES = 2.megabytes
  HTML_EXTENSION = /\A\.html?\z/i
  # Markdown uploads are rendered to a branded HTML page at ingest, so the
  # stored paste is still HTML -- only the accepted filename widens.
  MARKDOWN_EXTENSION = /\A\.(md|markdown)\z/i
  TITLE_TAG = %r{<title[^>]*>(.*?)</title>}im
  MAX_TITLE_LENGTH = 120
  MAX_PASSWORD_BYTES = 72

  CUSTOM_SUBDOMAIN_FORMAT = /\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
  LEGACY_VANITY_SUBDOMAINS = %w[ making-of lock-it-up mark-it-down ].freeze
  RESERVED_SUBDOMAINS = (
    %w[
      account admin api api-key api-keys app assets auth blog dashboard docs files help keys mail
      manage new p paste pastes raw render root session sessions sign-in sign-up signin signup
      static support uploads users www
    ] + LEGACY_VANITY_SUBDOMAINS
  ).freeze

  belongs_to :user, optional: true
  belongs_to :folder, optional: true
  has_many :paste_views, dependent: :destroy

  has_secure_password :password, validations: false

  # The plaintext update token exists only in memory right after create;
  # the database keeps a digest, so a leak can't be used to update pastes.
  attr_reader :update_token
  attr_readonly :token

  normalizes :custom_subdomain, with: ->(custom_subdomain) { custom_subdomain.to_s.strip.downcase.presence }

  validates :content, presence: true
  validates :original_filename, presence: true, length: { maximum: 255 }
  validate :original_filename_must_be_supported
  validate :password_must_fit_bcrypt_limit
  validates :custom_subdomain, length: { maximum: 63 }, allow_blank: true
  validates :custom_subdomain, format: { with: CUSTOM_SUBDOMAIN_FORMAT, message: :invalid_subdomain }, allow_blank: true
  validates :custom_subdomain, uniqueness: { case_sensitive: false }, allow_blank: true
  validate :content_must_fit_size_limit
  validate :custom_subdomain_must_be_available
  validate :folder_must_belong_to_user

  before_create :assign_token, :assign_update_token
  before_save :extract_title, if: :content_changed?

  # Pastes can never be deleted; they only change through `republish`,
  # which callers must authorize with `updatable_with?` first or own in the UI.
  before_destroy :prevent_destroy!, prepend: true

  scope :recent, -> { order(created_at: :desc, id: :desc) }
  # Dashboard listings only need each paste's byte size, not its (up to 2 MB)
  # body, so project octet_length instead of loading every document's content.
  scope :with_content_size, -> { select(column_names - [ "content" ], "octet_length(content) AS content_bytes") }

  class << self
    def from_upload(upload, attributes = {})
      filename = upload.original_filename
      new(attributes.merge(content: render_content(read_upload(upload), filename), original_filename: filename))
    end

    def read_upload(upload)
      upload.read(MAX_CONTENT_BYTES + 1).to_s.force_encoding(Encoding::UTF_8).scrub
    end

    # Markdown ingests are rendered to a branded HTML page; every other upload
    # is stored as-is. Keyed on the filename so both create and republish agree.
    def render_content(content, original_filename)
      return content unless markdown_filename?(original_filename)

      MarkdownDocument.new(content, filename: original_filename).to_html
    end

    def markdown_filename?(filename)
      File.extname(filename.to_s).match?(MARKDOWN_EXTENSION)
    end

    def digest_update_token(token)
      OpenSSL::Digest::SHA256.hexdigest(token)
    end

    def token_subdomain?(subdomain)
      subdomain.to_s.match?(/\A[a-z0-9]{#{TOKEN_LENGTH}}\z/o)
    end

    def custom_subdomain_candidate?(subdomain)
      value = subdomain.to_s.downcase
      value.match?(CUSTOM_SUBDOMAIN_FORMAT) && !RESERVED_SUBDOMAINS.include?(value)
    end

    def hosted_subdomain?(subdomain)
      value = subdomain.to_s.downcase
      token_subdomain?(value) || LEGACY_VANITY_SUBDOMAINS.include?(value) || custom_subdomain_candidate?(value)
    end

    def find_by_subdomain!(subdomain)
      value = subdomain.to_s.downcase
      where("LOWER(custom_subdomain) = :value OR LOWER(token) = :value", value:).take!
    end
  end

  def to_param
    token
  end

  def display_title
    title.presence || original_filename
  end

  def public_subdomain
    custom_subdomain.presence || token.downcase
  end

  def password_protected?
    password_digest.present?
  end

  def password=(unencrypted_password)
    @password = unencrypted_password
    super if unencrypted_password.nil? || unencrypted_password.to_s.bytesize <= MAX_PASSWORD_BYTES
  end

  def owned_by?(candidate)
    user_id.present? && candidate.present? && user_id == candidate.id
  end

  # Once a paste is claimed into an account, that account (its API key, or the
  # owner in the UI) is the sole update credential. A previously revealed
  # anonymous update token must stop working even if it leaked, so a non-owner
  # who still holds it can't keep overwriting a now-account-owned paste.
  def updatable_with?(candidate)
    user_id.blank? && update_token_digest.present? && candidate.present? &&
      ActiveSupport::SecurityUtils.secure_compare(update_token_digest, self.class.digest_update_token(candidate))
  end

  def republish(content:, original_filename: nil)
    self.original_filename = original_filename if original_filename.present?
    self.content = self.class.render_content(content, self.original_filename)
    save
  end

  def updated?
    updated_at > created_at
  end

  # Best-effort HTML-to-Markdown of the paste's content, for /p/<token>/markdown.
  # github_flavored gives fenced code blocks and tables; the conversion is lossy
  # and one-way (interactive/JS-heavy pastes reduce to little), which is expected
  # -- it's a convenience view, not a canonical representation. Never raises on
  # malformed markup: Nokogiri (which reverse_markdown uses) parses leniently.
  def to_markdown
    ReverseMarkdown.convert(content, github_flavored: true)
  end

  private
    def prevent_destroy!
      raise ActiveRecord::ReadOnlyRecord
    end

    def assign_token
      self.token = generate_unique_token
    end

    def assign_update_token
      @update_token = SecureRandom.base58(TOKEN_LENGTH)
      self.update_token_digest = self.class.digest_update_token(@update_token)
    end

    def generate_unique_token
      loop do
        token = SecureRandom.alphanumeric(TOKEN_LENGTH, chars: TOKEN_ALPHABET)
        break token unless self.class.where(
          "LOWER(token) = :token OR LOWER(custom_subdomain) = :token", token:
        ).exists?
      end
    end

    def extract_title
      self.title = content.to_s[TITLE_TAG, 1]&.then do |raw|
        CGI.unescapeHTML(raw).squish.truncate(MAX_TITLE_LENGTH).presence
      end
    end

    def original_filename_must_be_supported
      return if original_filename.blank?

      extension = File.extname(original_filename)
      return if extension.match?(HTML_EXTENSION) || extension.match?(MARKDOWN_EXTENSION)

      errors.add(:original_filename, :not_html)
    end

    def content_must_fit_size_limit
      return if content.blank? || content.bytesize <= MAX_CONTENT_BYTES

      errors.add(:content, :too_large)
    end

    def password_must_fit_bcrypt_limit
      return if password.nil? || password.bytesize <= MAX_PASSWORD_BYTES

      errors.add(:password, :too_long, count: MAX_PASSWORD_BYTES)
    end

    def custom_subdomain_must_be_available
      return if custom_subdomain.blank?

      # Only when the value is being set/changed, so a grandfathered vanity page
      # already holding a reserved slug (see db/seeds.rb) can still be re-saved.
      if custom_subdomain_changed? && RESERVED_SUBDOMAINS.include?(custom_subdomain)
        errors.add(:custom_subdomain, :reserved)
      end

      if self.class.where("LOWER(token) = ?", custom_subdomain).where.not(id: id).exists?
        errors.add(:custom_subdomain, :taken)
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
