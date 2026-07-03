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

  # The plaintext update token exists only in memory right after create;
  # the database keeps a digest, so a leak can't be used to update pastes.
  attr_reader :update_token
  attr_readonly :token

  validates :content, presence: true
  validates :original_filename, presence: true
  validate :original_filename_must_be_supported
  validate :content_must_fit_size_limit

  before_create :assign_token, :assign_update_token
  before_save :extract_title, if: :content_changed?

  # Pastes can never be deleted; they only change through `republish`,
  # which callers must authorize with `updatable_with?` first.
  before_destroy -> { raise ActiveRecord::ReadOnlyRecord }

  class << self
    def from_upload(upload)
      filename = upload.original_filename
      new(content: render_content(read_upload(upload), filename), original_filename: filename)
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
  end

  def to_param
    token
  end

  def display_title
    title.presence || original_filename
  end

  def updatable_with?(candidate)
    update_token_digest.present? && candidate.present? &&
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
        break token unless self.class.exists?(token:)
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
end
