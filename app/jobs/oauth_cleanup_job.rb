# Nightly inactivity-based cleanup for the MCP OAuth authorization server (see
# the OAuth plan, §6.5). Two sequential phases:
#
#   1. Revoke access tokens nobody has used in a long time -- refresh
#      capability dies with the token row's revocation, so this is how a
#      long-lived agent connection actually goes away.
#   2. Delete Dynamic Client Registration (DCR) applications that are old and
#      have nothing left pointing at them -- this is what absorbs Claude
#      Code's known re-registration churn (it may re-register per
#      authenticate) without ever touching a pre-registered, non-dynamic
#      client.
#
# Scheduled nightly via config/recurring.yml.
class OauthCleanupJob < ApplicationJob
  queue_as :default

  # An access token is stale once neither it (nor, if never used, its
  # creation) has seen activity within this window. COALESCE(last_used_at,
  # created_at) mirrors the throttled bump in McpController -- a token that
  # was never used at all is judged by its age instead.
  TOKEN_STALE_AFTER = 90.days

  # A dynamically registered application is abandoned once it is at least this
  # old AND has no *effective* (unrevoked and unexpired) token or grant left.
  # Non-dynamic (pre-registered) applications are never considered, regardless
  # of age or activity.
  DYNAMIC_APPLICATION_STALE_AFTER = 30.days

  # A token or grant is "effective" -- still able to authorize a request -- only
  # while it is unrevoked AND unexpired. A nil expires_in means the credential
  # never expires (Doorkeeper permits non-expiring access tokens), so it stays
  # effective indefinitely. An expired-but-unrevoked credential is inaccessible,
  # so it must NOT keep a stale dynamic app alive. Both Doorkeeper tables share
  # these column names, so the one predicate drives both subqueries below.
  EFFECTIVE_CREDENTIAL_SQL =
    "revoked_at IS NULL AND " \
    "(expires_in IS NULL OR created_at + expires_in * interval '1 second' > now())"

  def perform
    revoked_count = revoke_stale_tokens!
    deleted_count = delete_abandoned_dynamic_applications!

    Rails.logger.info(
      "OauthCleanupJob: revoked #{revoked_count} stale access token(s), " \
      "deleted #{deleted_count} abandoned dynamic application(s)"
    )
  end

  private
    # Active (non-revoked) tokens are revoked once COALESCE(last_used_at,
    # created_at) is older than TOKEN_STALE_AFTER. Uses Doorkeeper's own
    # `revoke` (sets revoked_at) rather than a bulk update so it stays the
    # single source of truth for what "revoked" means.
    def revoke_stale_tokens!
      stale_tokens = Doorkeeper::AccessToken
        .where(revoked_at: nil)
        .where("COALESCE(last_used_at, created_at) < ?", TOKEN_STALE_AFTER.ago)

      count = stale_tokens.count
      stale_tokens.find_each(&:revoke)
      count
    end

    # Dynamic applications old enough, with no effective token and no effective
    # grant, are destroyed outright. Abandonment is decided in a single bulk
    # query (two `NOT EXISTS`-style subqueries) rather than per-candidate
    # association loads, so it stays O(1) queries no matter how many candidates
    # there are. Doorkeeper's Application#destroy delete_all's its
    # access_tokens/access_grants associations, so any leftover (revoked or
    # expired) rows -- including ones this same run just revoked above --
    # disappear along with the application; that composition is intended.
    def delete_abandoned_dynamic_applications!
      abandoned = Doorkeeper::Application
        .where(dynamic: true)
        .where("created_at < ?", DYNAMIC_APPLICATION_STALE_AFTER.ago)
        .where.not(id: Doorkeeper::AccessToken.where(EFFECTIVE_CREDENTIAL_SQL).select(:application_id))
        .where.not(id: Doorkeeper::AccessGrant.where(EFFECTIVE_CREDENTIAL_SQL).select(:application_id))
        .to_a

      abandoned.each(&:destroy)
      abandoned.size
    end
end
