# frozen_string_literal: true

# Doorkeeper tables for the MCP OAuth authorization server, edited from the
# stock generator output for this app's decisions (see the MCP OAuth plan):
#
# - oauth_applications.secret is NULLable: every MCP client is a public
#   (non-confidential) client and never receives a secret.
# - oauth_applications.dynamic marks applications minted through RFC 7591
#   Dynamic Client Registration (a later task adds the endpoint); it drives
#   the "unverified client" consent labeling and inactivity cleanup.
# - oauth_access_grants carries the opt-in PKCE columns (code_challenge,
#   code_challenge_method) -- S256 is mandatory for this server.
# - resource on grants AND tokens stores the canonical RFC 8707 resource
#   indicator, persisted through the whole grant -> token -> refresh chain.
# - previous_refresh_token is deliberately ABSENT from oauth_access_tokens:
#   Doorkeeper feature-detects that column (AccessToken.refresh_token_revoked_on_use?)
#   and its absence is what makes refresh rotation immediate, with no
#   grace window for the rotated-out token.
# - last_used_at supports inactivity-based cleanup (a later task bumps it,
#   throttled, from the MCP endpoint).
class CreateDoorkeeperTables < ActiveRecord::Migration[8.1]
  def change
    create_table :oauth_applications do |t|
      t.string  :name,    null: false
      t.string  :uid,     null: false
      # NULLable on purpose: public clients never get a secret.
      t.string  :secret,  null: true

      t.text    :redirect_uri, null: false
      t.string  :scopes,       null: false, default: ""
      t.boolean :confidential, null: false, default: true
      # True for clients created via Dynamic Client Registration (RFC 7591).
      t.boolean :dynamic,      null: false, default: false
      t.timestamps             null: false
    end

    add_index :oauth_applications, :uid, unique: true

    create_table :oauth_access_grants do |t|
      t.references :resource_owner,  null: false
      t.references :application,     null: false
      t.string   :token,             null: false
      t.integer  :expires_in,        null: false
      t.text     :redirect_uri,      null: false
      t.string   :scopes,            null: false, default: ""
      t.datetime :created_at,        null: false
      t.datetime :revoked_at

      # PKCE (RFC 7636) -- their presence enables Doorkeeper's PKCE support.
      t.string :code_challenge
      t.string :code_challenge_method

      # Canonical RFC 8707 resource indicator this grant was issued for.
      t.string :resource
    end

    add_index :oauth_access_grants, :token, unique: true
    add_foreign_key(
      :oauth_access_grants,
      :oauth_applications,
      column: :application_id
    )

    create_table :oauth_access_tokens do |t|
      t.references :resource_owner, index: true
      t.references :application,    null: false

      t.string :token, null: false

      t.string   :refresh_token
      t.integer  :expires_in
      t.string   :scopes
      t.datetime :created_at, null: false
      t.datetime :revoked_at

      # Canonical RFC 8707 resource indicator, carried across refreshes.
      t.string :resource

      # Bumped (throttled) on MCP use; drives inactivity-based cleanup.
      t.datetime :last_used_at

      # NOTE: no previous_refresh_token column -- see the class comment.
    end

    add_index :oauth_access_tokens, :token, unique: true
    add_index :oauth_access_tokens, :refresh_token, unique: true

    add_foreign_key(
      :oauth_access_tokens,
      :oauth_applications,
      column: :application_id
    )

    # Grants and tokens always belong to a signed-in user.
    add_foreign_key :oauth_access_grants, :users, column: :resource_owner_id
    add_foreign_key :oauth_access_tokens, :users, column: :resource_owner_id
  end
end
