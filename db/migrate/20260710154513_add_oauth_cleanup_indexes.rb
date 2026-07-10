class AddOauthCleanupIndexes < ActiveRecord::Migration[8.1]
  def change
    # Supports OauthCleanupJob phase 2's candidate scan: dynamic apps past an
    # age threshold.
    add_index :oauth_applications, [ :dynamic, :created_at ]

    # Supports the "no effective credential" NOT-EXISTS subqueries: both filter
    # by application_id among non-revoked rows. Partial indexes stay small (only
    # live rows) and directly serve the `revoked_at IS NULL` predicate.
    add_index :oauth_access_tokens, :application_id,
      where: "revoked_at IS NULL", name: "index_oauth_access_tokens_active_by_application"
    add_index :oauth_access_grants, :application_id,
      where: "revoked_at IS NULL", name: "index_oauth_access_grants_active_by_application"
  end
end
