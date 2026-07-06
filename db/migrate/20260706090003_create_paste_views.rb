class CreatePasteViews < ActiveRecord::Migration[8.1]
  def change
    create_table :paste_views do |t|
      t.references :paste, null: false, foreign_key: true
      t.references :user, foreign_key: true
      t.string :source, null: false
      t.string :ip_address_digest
      t.text :user_agent
      t.text :referrer

      t.timestamps
    end

    add_index :paste_views, [ :paste_id, :created_at ]
    add_index :paste_views, [ :source, :created_at ]
  end
end
