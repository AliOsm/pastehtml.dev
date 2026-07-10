require "test_helper"

# The apex host serves the app; deploy.yml also answers on `www.<apex>` and the
# `*.<apex>` wildcard. OAuth/MCP routes are constrained to the canonical apex
# host only, so a signed-in user who lands on the www host and clicks a
# relative app link (e.g. "Connected agents") would otherwise 404. A routes-
# level 308 folds `www.<apex>` back onto the apex before anything else runs. It
# is a 308 (not 301) so a POST is redirected without being rewritten to GET.
class WwwHostRedirectTest < ActionDispatch::IntegrationTest
  APEX = McpOauth::CONFIG[:host]

  test "a request on the www host permanently redirects to the apex, preserving the path" do
    host! "www.#{APEX}"

    get "/oauth/authorized_applications"

    assert_response :permanent_redirect
    assert_equal "http://#{APEX}/oauth/authorized_applications", @response.location
  end

  test "the www redirect preserves the query string" do
    host! "www.#{APEX}"

    get "/oauth/authorized_applications?foo=bar"

    assert_response :permanent_redirect
    assert_equal "http://#{APEX}/oauth/authorized_applications?foo=bar", @response.location
  end

  test "the root of the www host redirects to the apex root" do
    host! "www.#{APEX}"

    get "/"

    assert_response :permanent_redirect
    assert_equal "http://#{APEX}/", @response.location
  end

  test "a POST on the www host is redirected with 308, preserving the method" do
    host! "www.#{APEX}"

    post "/api/pastes", params: { filename: "x.html" }

    # 308 tells the client to replay the POST (with its body) against the apex,
    # rather than a 301 that browsers may downgrade to GET.
    assert_response :permanent_redirect
    assert_equal "http://#{APEX}/api/pastes", @response.location
  end

  test "the canonical apex host is not redirected" do
    host! APEX

    get "/oauth/authorized_applications"

    assert_not_equal 308, @response.status
    assert_not_equal 301, @response.status
  end

  test "a paste-origin host is not caught by the www rule" do
    host! "#{'a' * 32}.#{APEX}"

    get "/"

    # An unknown token subdomain 404s through the paste routing; either way it is
    # never our redirect back to the apex.
    assert_not_equal 308, @response.status
    assert_not_equal 301, @response.status
  end
end
