class AddUpdateTokenDigestToPastes < ActiveRecord::Migration[8.1]
  def change
    add_column :pastes, :update_token_digest, :string
  end
end
