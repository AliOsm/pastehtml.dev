class AddLowerTokenIndexToPastes < ActiveRecord::Migration[8.1]
  def change
    # Subdomain lookups are case-insensitive (browsers lowercase hostnames),
    # and tokens created before the lowercase alphabet are mixed-case.
    add_index :pastes, "lower(token)", name: "index_pastes_on_lower_token"
  end
end
