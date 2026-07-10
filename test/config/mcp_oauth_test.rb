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
end
