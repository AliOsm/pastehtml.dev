class AddSuspiciousToPastes < ActiveRecord::Migration[8.1]
  def change
    add_column :pastes, :suspicious, :boolean, default: false, null: false
  end
end
