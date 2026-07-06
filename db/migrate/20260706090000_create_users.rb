class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email_address, null: false
      t.string :password_digest, null: false

      t.timestamps
    end

    add_index :users, "lower(email_address)", unique: true, name: "index_users_on_lower_email_address"
  end
end
