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

  # ActionDispatch's integration harness normalizes the request path before it is
  # dispatched, so `post "/oauth//register"` would not actually exercise a
  # repeated-slash PATH_INFO. Drive the real middleware stack directly with a
  # crafted env -- the form a raw HTTP client (curl, Cloudflare) can send, which
  # Rails' router still normalizes and routes -- to prove the guard catches it.
  test "an oversized repeated-slash DCR request is rejected full-stack" do
    before = Doorkeeper::Application.count

    status, = call_stack("/oauth//register", oversize_dcr_body)

    assert_equal 413, status
    assert_equal before, Doorkeeper::Application.count
  end

  test "an oversized repeated-slash /mcp request is rejected full-stack" do
    status, = call_stack("//mcp", oversize_mcp_body)

    assert_equal 413, status
  end

  test "a normal DCR body still registers (regression: within-limit body passes through)" do
    post "/oauth/register",
      params: { redirect_uris: [ "http://127.0.0.1:51000/callback" ] }.to_json,
      headers: JSON_HEADERS

    assert_response :created
    assert response.parsed_body["client_id"].present?
  end

  private
    # Runs the full Rack middleware stack (McpBodyLimit included) against a raw
    # env whose PATH_INFO keeps the repeated slash the integration harness would
    # otherwise normalize away.
    def call_stack(path_info, body)
      env = Rack::MockRequest.env_for("/", method: "POST", "CONTENT_TYPE" => "application/json")
      env["PATH_INFO"] = path_info
      env["rack.input"] = StringIO.new(body)
      env["CONTENT_LENGTH"] = body.bytesize.to_s
      status, _headers, response_body = Rails.application.call(env)
      response_body.close if response_body.respond_to?(:close)
      [ status ]
    end

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
