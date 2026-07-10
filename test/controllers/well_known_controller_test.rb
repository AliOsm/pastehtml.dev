require "test_helper"

# RFC 9728 (protected resource metadata) + RFC 8414 (authorization server
# metadata) discovery documents. Both are static JSON derived exclusively
# from McpOauth::CONFIG -- never from request headers -- and must be
# reachable with no session, since MCP clients probe them before any login
# has happened.
class WellKnownControllerTest < ActionDispatch::IntegrationTest
  ISSUER = McpOauth::CONFIG[:issuer]

  test "protected resource metadata at the root well-known path" do
    get "/.well-known/oauth-protected-resource"

    assert_response :success
    assert_equal "application/json", response.media_type
    assert_equal expected_protected_resource_metadata, response.parsed_body
  end

  test "protected resource metadata at the mcp-suffixed well-known path" do
    get "/.well-known/oauth-protected-resource/mcp"

    assert_response :success
    assert_equal "application/json", response.media_type
    assert_equal expected_protected_resource_metadata, response.parsed_body
  end

  test "protected resource metadata is reachable with no session" do
    get "/.well-known/oauth-protected-resource"

    assert_response :success
    assert_nil session[:return_to_after_authenticating]
  end

  test "authorization server metadata returns all required fields" do
    get "/.well-known/oauth-authorization-server"

    assert_response :success
    assert_equal "application/json", response.media_type
    body = response.parsed_body

    assert_equal ISSUER, body["issuer"]
    assert_equal "#{ISSUER}/oauth/authorize", body["authorization_endpoint"]
    assert_equal "#{ISSUER}/oauth/token", body["token_endpoint"]
    assert_equal "#{ISSUER}/oauth/register", body["registration_endpoint"]
    assert_equal "#{ISSUER}/oauth/revoke", body["revocation_endpoint"]
    assert_equal %w[authorization_code refresh_token], body["grant_types_supported"]
    assert_equal %w[code], body["response_types_supported"]
    assert_equal %w[mcp:read mcp:write], body["scopes_supported"]
  end

  test "authorization server metadata advertises S256 PKCE support" do
    get "/.well-known/oauth-authorization-server"

    assert_equal [ "S256" ], response.parsed_body["code_challenge_methods_supported"]
  end

  test "authorization server metadata advertises no client authentication (public clients)" do
    get "/.well-known/oauth-authorization-server"

    assert_equal [ "none" ], response.parsed_body["token_endpoint_auth_methods_supported"]
  end

  test "authorization server metadata is reachable with no session" do
    get "/.well-known/oauth-authorization-server"

    assert_response :success
    assert_nil session[:return_to_after_authenticating]
  end

  test "every endpoint URL in both documents starts with the configured issuer" do
    get "/.well-known/oauth-protected-resource"
    prm = response.parsed_body
    assert prm["resource"].start_with?(ISSUER)
    prm["authorization_servers"].each { |url| assert url.start_with?(ISSUER) }

    get "/.well-known/oauth-authorization-server"
    asm = response.parsed_body
    %w[issuer authorization_endpoint token_endpoint registration_endpoint revocation_endpoint].each do |key|
      assert asm[key].start_with?(ISSUER), "expected #{key} (#{asm[key]}) to start with #{ISSUER}"
    end
  end

  private
    def expected_protected_resource_metadata
      {
        "resource" => McpOauth::CONFIG[:resource_uri],
        "authorization_servers" => [ McpOauth::CONFIG[:issuer] ],
        "scopes_supported" => %w[mcp:read mcp:write],
        "bearer_methods_supported" => %w[header]
      }
    end
end
