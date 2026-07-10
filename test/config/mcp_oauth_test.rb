require "test_helper"

class McpOauthTest < ActiveSupport::TestCase
  test "CONFIG is a frozen hash with frozen string values" do
    assert_predicate McpOauth::CONFIG, :frozen?

    McpOauth::CONFIG.each_value do |value|
      assert_predicate value, :frozen?
    end
  end

  test "CONFIG has exactly the four expected keys" do
    assert_equal %i[issuer resource_uri host protected_resource_metadata_url].sort, McpOauth::CONFIG.keys.sort
  end

  test "CONFIG uses the www.example.com defaults in the test environment" do
    assert_equal "http://www.example.com", McpOauth::CONFIG[:issuer]
    assert_equal "www.example.com", McpOauth::CONFIG[:host]
  end

  test "resource_uri is derived from the issuer" do
    assert McpOauth::CONFIG[:resource_uri].start_with?(McpOauth::CONFIG[:issuer])
    assert McpOauth::CONFIG[:resource_uri].end_with?("/mcp")
  end

  test "protected_resource_metadata_url is derived from the issuer" do
    assert McpOauth::CONFIG[:protected_resource_metadata_url].start_with?(McpOauth::CONFIG[:issuer])
    assert_equal "#{McpOauth::CONFIG[:issuer]}/.well-known/oauth-protected-resource", McpOauth::CONFIG[:protected_resource_metadata_url]
  end

  # CONFIG itself is built once at boot from the test env, so the §6.0 dev
  # config (issuer http://localhost:3000) can't be observed by reloading the
  # initializer. Call the same pure derivation the initializer uses instead.
  test "build_config derives the dev issuer's parts from MCP_OAUTH_ISSUER=http://localhost:3000" do
    config = McpOauth.build_config(env: "development", env_vars: { "MCP_OAUTH_ISSUER" => "http://localhost:3000" })

    assert_equal "http://localhost:3000", config[:issuer]
    assert_equal "localhost", config[:host]
    assert_equal "http://localhost:3000/mcp", config[:resource_uri]
    assert_equal "http://localhost:3000/.well-known/oauth-protected-resource", config[:protected_resource_metadata_url]
  end

  # NOTE: the code review's assumption that Paste.hosted_subdomain?("localhost")
  # is false does NOT hold -- "localhost" is a plain, unreserved custom-subdomain
  # candidate at this layer, so the call returns true. The app is still safe:
  # ApplicationController#paste_origin_request? never even calls
  # Paste.hosted_subdomain? for the bare app host "localhost", because its
  # `subdomainish_host` guard requires >= 2 labels ending in "localhost" (e.g.
  # "slug.localhost"), which the single-label host isn't. See that method for
  # the real invariant. Asserting the review's literal claim here would assert
  # something false about Paste, so it's intentionally omitted -- flagged for
  # the reviewer instead of silently "fixed" by reserving "localhost" in
  # Paste::RESERVED_SUBDOMAINS (a user-facing behavior change out of scope for
  # this test-only ticket).
end
