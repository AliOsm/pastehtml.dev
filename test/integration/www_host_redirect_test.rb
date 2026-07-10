require "test_helper"

# The apex host serves the app; deploy.yml also answers on `www.<apex>` and the
# `*.<apex>` wildcard. OAuth/MCP routes are constrained to the canonical apex
# host only, so a signed-in user who lands on the www host and clicks a
# relative app link (e.g. "Connected agents") would otherwise 404. A routes-
# level 301 folds `www.<apex>` back onto the apex before anything else runs.
class WwwHostRedirectTest < ActionDispatch::IntegrationTest
  APEX = McpOauth::CONFIG[:host]

  test "a request on the www host 301-redirects to the apex, preserving the path" do
    host! "www.#{APEX}"

    get "/oauth/authorized_applications"

    assert_response :moved_permanently
    assert_equal "http://#{APEX}/oauth/authorized_applications", @response.location
  end

  test "the www redirect preserves the query string" do
    host! "www.#{APEX}"

    get "/oauth/authorized_applications?foo=bar"

    assert_response :moved_permanently
    assert_equal "http://#{APEX}/oauth/authorized_applications?foo=bar", @response.location
  end

  test "the root of the www host redirects to the apex root" do
    host! "www.#{APEX}"

    get "/"

    assert_response :moved_permanently
    assert_equal "http://#{APEX}/", @response.location
  end

  test "the canonical apex host is not redirected" do
    host! APEX

    get "/oauth/authorized_applications"

    assert_not_equal 301, @response.status
  end

  test "a paste-origin host is not caught by the www rule" do
    host! "#{'a' * 32}.#{APEX}"

    get "/"

    # An unknown token subdomain 404s through the paste routing; either way it is
    # never our 301 back to the apex.
    assert_not_equal 301, @response.status
  end
end
