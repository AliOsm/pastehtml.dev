class CreateFoldersAndExtendPastes < ActiveRecord::Migration[8.1]
  def change
    create_table :folders do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false

      t.timestamps
    end
    add_index :folders, "user_id, lower(name)", unique: true, name: "index_folders_on_user_id_and_lower_name"

    add_reference :pastes, :user, foreign_key: true
    add_reference :pastes, :folder, foreign_key: true
    add_column :pastes, :custom_subdomain, :string
    add_column :pastes, :password_digest, :string
    add_column :pastes, :views_count, :integer, null: false, default: 0
    add_index :pastes, "lower(custom_subdomain)", unique: true,
      where: "custom_subdomain IS NOT NULL", name: "index_pastes_on_lower_custom_subdomain"
  end
end
