require "test_helper"

# Nightly inactivity-based cleanup for the MCP OAuth authorization server:
# phase 1 revokes stale access tokens, phase 2 deletes abandoned Dynamic
# Client Registration (DCR) applications. See OauthCleanupJob for the exact
# thresholds and the OAuth plan's §6.5 for the rationale.
class OauthCleanupJobTest < ActiveJob::TestCase
  RESOURCE = McpOauth::CONFIG[:resource_uri]

  setup do
    @user = users(:alice)
  end

  # --- Phase 1: revoke stale tokens -----------------------------------------

  test "a token last used 91 days ago is revoked" do
    token = create_token(last_used_at: 91.days.ago)

    OauthCleanupJob.perform_now

    assert_predicate token.reload, :revoked?
  end

  test "a token with nil last_used_at but created_at 91 days ago is revoked (COALESCE path)" do
    token = create_token(last_used_at: nil, created_at: 91.days.ago)

    OauthCleanupJob.perform_now

    assert_predicate token.reload, :revoked?
  end

  test "a token last used 89 days ago is left untouched" do
    token = create_token(last_used_at: 89.days.ago)

    OauthCleanupJob.perform_now

    assert_not token.reload.revoked?
  end

  test "an already-revoked token is untouched (idempotent)" do
    revoked_at = 100.days.ago.change(usec: 0)
    token = create_token(last_used_at: 91.days.ago, revoked_at: revoked_at)

    OauthCleanupJob.perform_now

    assert_equal revoked_at, token.reload.revoked_at
  end

  # --- Phase 2: delete abandoned dynamic applications -----------------------

  test "a dynamic app 31 days old with only revoked tokens is deleted, along with its tokens" do
    application = create_application(dynamic: true, created_at: 31.days.ago)
    token = create_token(application: application, revoked_at: 1.day.ago)

    OauthCleanupJob.perform_now

    assert_not Doorkeeper::Application.exists?(application.id)
    assert_not Doorkeeper::AccessToken.exists?(token.id)
  end

  test "a dynamic app 31 days old with one active token is kept" do
    application = create_application(dynamic: true, created_at: 31.days.ago)
    create_token(application: application, last_used_at: 1.day.ago)

    OauthCleanupJob.perform_now

    assert Doorkeeper::Application.exists?(application.id)
  end

  test "a dynamic app 29 days old with nothing is kept (too young)" do
    application = create_application(dynamic: true, created_at: 29.days.ago)

    OauthCleanupJob.perform_now

    assert Doorkeeper::Application.exists?(application.id)
  end

  test "a NON-dynamic app 31 days old with nothing is kept" do
    application = create_application(dynamic: false, created_at: 31.days.ago)

    OauthCleanupJob.perform_now

    assert Doorkeeper::Application.exists?(application.id)
  end

  test "a dynamic app 31 days old with an active grant but no tokens is kept" do
    application = create_application(dynamic: true, created_at: 31.days.ago)
    create_grant(application: application)

    OauthCleanupJob.perform_now

    assert Doorkeeper::Application.exists?(application.id)
  end

  # An EXPIRED (but never revoked) grant is inaccessible -- its short TTL has
  # lapsed -- so it must NOT keep an abandoned dynamic app alive. This is the
  # regression the old `revoked_at: nil` abandonment check missed.
  test "a dynamic app 31 days old with only an expired grant is deleted" do
    application = create_application(dynamic: true, created_at: 31.days.ago)
    create_grant(application: application, created_at: 31.days.ago)

    OauthCleanupJob.perform_now

    assert_not Doorkeeper::Application.exists?(application.id)
  end

  # Same for an unrevoked-but-expired access token: recent activity keeps phase
  # 1 from revoking it, yet it is expired, so it cannot keep the app alive.
  test "a dynamic app 31 days old with only an expired (unrevoked) token is deleted" do
    application = create_application(dynamic: true, created_at: 31.days.ago)
    create_token(application: application, last_used_at: 1.day.ago, created_at: 40.days.ago)

    OauthCleanupJob.perform_now

    assert_not Doorkeeper::Application.exists?(application.id)
  end

  # A nil expires_in means the token never expires (Doorkeeper permits this), so
  # it stays effective indefinitely and keeps the app.
  test "a dynamic app 31 days old with a non-expiring (nil expires_in) token is kept" do
    application = create_application(dynamic: true, created_at: 31.days.ago)
    token = create_token(application: application, last_used_at: 1.day.ago)
    token.update_columns(expires_in: nil)

    OauthCleanupJob.perform_now

    assert Doorkeeper::Application.exists?(application.id)
  end

  # The age gate still wins: an expired credential on a too-young app is moot.
  test "a dynamic app 29 days old with an expired grant is kept (too young)" do
    application = create_application(dynamic: true, created_at: 29.days.ago)
    create_grant(application: application, created_at: 40.days.ago)

    OauthCleanupJob.perform_now

    assert Doorkeeper::Application.exists?(application.id)
  end

  # A mix: one effective token outweighs any number of expired credentials.
  test "a dynamic app 31 days old with an expired grant but one active token is kept" do
    application = create_application(dynamic: true, created_at: 31.days.ago)
    create_token(application: application, last_used_at: 1.day.ago)
    create_grant(application: application, created_at: 40.days.ago)

    OauthCleanupJob.perform_now

    assert Doorkeeper::Application.exists?(application.id)
  end

  # --- Composition: phase 1's revocation feeds phase 2's deletion -----------

  test "phase 1 revoking a stale token lets phase 2 delete the now-abandoned dynamic app in the same run" do
    application = create_application(dynamic: true, created_at: 31.days.ago)
    token = create_token(application: application, last_used_at: 91.days.ago)

    OauthCleanupJob.perform_now

    # Without phase 1's revocation this token would still be "active" and
    # phase 2 would keep the application (see the "one active token is kept"
    # test above) -- both the application and the token it fed into phase 2
    # are gone, proving the two phases composed within a single run.
    assert_not Doorkeeper::Application.exists?(application.id)
    assert_not Doorkeeper::AccessToken.exists?(token.id)
  end

  # --- Logging ---------------------------------------------------------------

  test "logs a single summary line with both counts" do
    create_token(last_used_at: 91.days.ago)
    application = create_application(dynamic: true, created_at: 31.days.ago)
    create_token(application: application, revoked_at: 1.day.ago)

    logged = capture_rails_logger_info { OauthCleanupJob.perform_now }

    assert_equal 1, logged.count { |line| line.include?("OauthCleanupJob") }
    assert_includes logged.join, "revoked 1"
    assert_includes logged.join, "deleted 1"
  end

  private
    def create_application(dynamic:, created_at: Time.current)
      application = Doorkeeper::Application.create!(
        name: "Test App #{SecureRandom.hex(4)}",
        redirect_uri: "http://127.0.0.1:#{rand(20_000..60_000)}/callback",
        scopes: "mcp:read mcp:write",
        confidential: false,
        dynamic: dynamic
      )
      application.update_columns(created_at: created_at)
      application
    end

    def create_token(application: nil, user: @user, last_used_at: nil, created_at: nil, revoked_at: nil)
      application ||= create_application(dynamic: false)
      token = Doorkeeper::AccessToken.create!(
        application: application,
        resource_owner_id: user.id,
        scopes: "mcp:read mcp:write",
        expires_in: 3600,
        resource: RESOURCE
      )
      token.update_columns(
        last_used_at: last_used_at,
        created_at: created_at || token.created_at,
        revoked_at: revoked_at
      )
      token
    end

    def create_grant(application:, user: @user, revoked_at: nil, created_at: nil, expires_in: 600)
      grant = Doorkeeper::AccessGrant.create!(
        application: application,
        resource_owner_id: user.id,
        redirect_uri: application.redirect_uri,
        expires_in: expires_in,
        scopes: "mcp:read mcp:write",
        resource: RESOURCE
      )
      columns = { revoked_at: revoked_at, created_at: created_at }.compact
      grant.update_columns(columns) if columns.any?
      grant
    end

    def capture_rails_logger_info
      lines = []
      original_logger = Rails.logger
      recorder = Logger.new(StringIO.new)
      recorder.define_singleton_method(:info) { |msg = nil, &block| lines << (msg || block&.call).to_s }
      Rails.logger = recorder
      yield
      lines
    ensure
      Rails.logger = original_logger
    end
end
