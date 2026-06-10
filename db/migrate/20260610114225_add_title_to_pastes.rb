class AddTitleToPastes < ActiveRecord::Migration[8.1]
  def change
    add_column :pastes, :title, :string
  end
end
