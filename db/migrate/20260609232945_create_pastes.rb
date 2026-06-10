class CreatePastes < ActiveRecord::Migration[8.1]
  def change
    create_table :pastes do |t|
      t.string :token, null: false
      t.text :content, null: false
      t.string :original_filename, null: false

      t.timestamps
    end
    add_index :pastes, :token, unique: true
  end
end
