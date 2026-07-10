require "test_helper"

# Full-stack coverage for McpBodyLimit: a real oversized body driven through the
# entire Rails middleware stack and router must be rejected before the endpoint
# parses it, on both the canonical paths and their trailing-slash variants.
class McpBodyLimitIntegrationTest < ActionDispatch::IntegrationTest
  OVERSIZE = ("a" * (McpBodyLimit::MAX_BYTES + 2048)).freeze
  JSON_HEADERS = { "Content-Type" => "application/json" }.freeze

  test "an oversized DCR body is rejected with 413 before registration" do
    before = Doorkeeper::Application.count

    post "/oauth/register", params: oversize_dcr_body, headers: JSON_HEADERS

    assert_response :content_too_large
    assert_equal before, Doorkeeper::Application.count, "no application should be created"
  end

  test "an oversized DCR body on the trailing-slash route is also rejected" do
    before = Doorkeeper::Application.count

    post "/oauth/register/", params: oversize_dcr_body, headers: JSON_HEADERS

    assert_response :content_too_large
    assert_equal before, Doorkeeper::Application.count
  end

  test "an oversized /mcp body is rejected with 413" do
    token = mint_token
    post "/mcp", params: oversize_mcp_body,
      headers: JSON_HEADERS.merge("Authorization" => "Bearer #{token.plaintext_token}")

    assert_response :content_too_large
  end

  test "a normal DCR body still registers (regression: within-limit body passes through)" do
    post "/oauth/register",
      params: { redirect_uris: [ "http://127.0.0.1:51000/callback" ] }.to_json,
      headers: JSON_HEADERS

    assert_response :created
    assert response.parsed_body["client_id"].present?
  end

  private
    def oversize_dcr_body
      { redirect_uris: [ "http://127.0.0.1:51000/callback" ], pad: OVERSIZE }.to_json
    end

    def oversize_mcp_body
      { jsonrpc: "2.0", id: 1, method: "initialize", params: { pad: OVERSIZE } }.to_json
    end

    def mint_token
      application = oauth_applications(:mcp_client)
      Doorkeeper::AccessToken.create!(
        application: application,
        resource_owner_id: users(:alice).id,
        scopes: "mcp:read mcp:write",
        expires_in: 3600,
        resource: McpOauth::CONFIG[:resource_uri]
      )
    end
end
