class Folder < ApplicationRecord
  belongs_to :user
  has_many :pastes, dependent: :nullify
  has_many :api_keys, dependent: :nullify

  before_destroy :revoke_scoped_api_keys, prepend: true

  normalizes :name, with: ->(name) { name.to_s.strip }

  validates :name, presence: true, length: { maximum: 80 },
    uniqueness: { scope: :user_id, case_sensitive: false }

  private
    def revoke_scoped_api_keys
      api_keys.active.update_all(revoked_at: Time.current, updated_at: Time.current)
    end
end
