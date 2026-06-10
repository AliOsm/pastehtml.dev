require "test_helper"

class PwaTest < ActionDispatch::IntegrationTest
  test "serves the web app manifest" do
    get pwa_manifest_url(format: :json)

    assert_response :success
    manifest = JSON.parse(response.body)
    assert_equal "pastehtml.dev", manifest["name"]
    assert_equal "standalone", manifest["display"]
    assert_equal 4, manifest["icons"].size
    assert(manifest["icons"].any? { |icon| icon["purpose"] == "maskable" })
  end

  test "serves the service worker at a root path" do
    get pwa_service_worker_url(format: :js)

    assert_response :success
    assert_includes response.body, "OFFLINE_URL"
  end
end
