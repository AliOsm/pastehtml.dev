require "test_helper"

# Doorkeeper's stock "authorized applications" screen, restyled as the
# account's "Connected agents" screen (Oauth::AuthorizedApplicationsController)
# -- lists every OAuth client (Claude Code, Codex, ...) the signed-in user has
# authorized for the MCP endpoint, and lets them revoke access.
class Oauth::AuthorizedApplicationsControllerTest < ActionDispatch::IntegrationTest
  RESOURCE = McpOauth::CONFIG[:resource_uri]

  test "index requires authentication" do
    get oauth_authorized_applications_url

    assert_response :see_other
    assert_redirected_to new_session_url
  end

  test "lists only the current user's authorized applications" do
    sign_in_as users(:alice)
    mint_token(user: users(:alice), application: oauth_applications(:mcp_client))
    mint_token(user: users(:bob), application: oauth_applications(:dynamic_client))

    get oauth_authorized_applications_url
    assert_response :success

    # Scoped to the app card itself (article h2), not a loose body substring
    # match: the page's own copy names "Codex" as an example agent, which
    # would otherwise collide with the dynamic_client fixture of that name.
    assert_select "article h2", text: oauth_applications(:mcp_client).name
    assert_select "article h2", text: oauth_applications(:dynamic_client).name, count: 0
  end

  test "shows the unverified label only for dynamically registered clients" do
    sign_in_as users(:alice)
    mint_token(user: users(:alice), application: oauth_applications(:mcp_client))
    mint_token(user: users(:alice), application: oauth_applications(:dynamic_client))

    get oauth_authorized_applications_url
    assert_response :success

    unverified_label = I18n.t("doorkeeper.authorizations.new.unverified_client")
    assert_equal 1, response.body.scan(unverified_label).count
    assert_includes response.body, oauth_applications(:dynamic_client).name
  end

  test "shows the redirect host, not the full redirect URI" do
    sign_in_as users(:alice)
    mint_token(user: users(:alice), application: oauth_applications(:mcp_client))

    get oauth_authorized_applications_url
    assert_response :success

    assert_includes response.body, "127.0.0.1"
    assert_not_includes response.body, "/callback"
  end

  test "shows human scope labels for granted scopes" do
    sign_in_as users(:alice)
    mint_token(user: users(:alice), application: oauth_applications(:mcp_client), scopes: "mcp:read mcp:pastes:write mcp:folders:write")

    get oauth_authorized_applications_url
    assert_response :success

    assert_includes response.body, I18n.t("doorkeeper.scopes.mcp:read")
    assert_includes response.body, I18n.t("doorkeeper.scopes.mcp:pastes:write")
    assert_includes response.body, I18n.t("doorkeeper.scopes.mcp:folders:write")
  end

  test "shows a never-used state and a formatted last-used date" do
    sign_in_as users(:alice)
    never_used_app = oauth_applications(:mcp_client)
    used_app = oauth_applications(:dynamic_client)
    mint_token(user: users(:alice), application: never_used_app)
    used_token = mint_token(user: users(:alice), application: used_app)
    used_token.update!(last_used_at: Time.zone.local(2026, 3, 4, 10, 0, 0))

    get oauth_authorized_applications_url
    assert_response :success

    assert_includes response.body, I18n.t("connected_agents.meta.never_used")
    assert_includes response.body, I18n.l(Date.new(2026, 3, 4), format: :long)
  end

  test "revoking an application invalidates its access token and refresh token" do
    sign_in_as users(:alice)
    application = oauth_applications(:mcp_client)
    token = mint_token(user: users(:alice), application: application, use_refresh_token: true)
    access_token = token.plaintext_token
    refresh_token = token.plaintext_refresh_token

    assert_difference -> { Doorkeeper::AccessToken.active_for(users(:alice)).count }, -1 do
      delete oauth_authorized_application_url(application)
    end
    assert_response :see_other
    assert_redirected_to oauth_authorized_applications_url

    get oauth_authorized_applications_url
    assert_not_includes response.body, application.name

    post "/mcp", params: { jsonrpc: "2.0", id: 1, method: "ping" }.to_json,
      headers: {
        "Authorization" => "Bearer #{access_token}",
        "Content-Type" => "application/json",
        "Accept" => "application/json, text/event-stream"
      }
    assert_response :unauthorized
    assert_includes response.headers["WWW-Authenticate"], %(error="invalid_token")

    post "/oauth/token", params: {
      grant_type: "refresh_token",
      client_id: application.uid,
      refresh_token: refresh_token,
      resource: RESOURCE
    }
    assert_response :bad_request
    assert_equal "invalid_grant", response.parsed_body["error"]
  end

  test "empty state when no applications are connected" do
    sign_in_as users(:alice)

    get oauth_authorized_applications_url
    assert_response :success
    assert_includes response.body, I18n.t("connected_agents.empty_body")
  end

  test "the account nav shows a Connected agents link for signed-in users" do
    sign_in_as users(:alice)

    get pastes_url
    assert_response :success
    assert_select "a[href=?]", oauth_authorized_applications_path
  end

  private
    def sign_in_as(user)
      post session_url, params: { email_address: user.email_address, password: "password" }
      assert_redirected_to pastes_url
    end

    def mint_token(user:, application:, scopes: "mcp:read mcp:pastes:write mcp:folders:write", resource: RESOURCE, use_refresh_token: false)
      Doorkeeper::AccessToken.create!(
        application: application,
        resource_owner_id: user.id,
        scopes: scopes,
        expires_in: 3600,
        resource: resource,
        use_refresh_token: use_refresh_token
      )
    end
end
