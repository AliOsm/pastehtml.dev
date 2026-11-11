require "test_helper"

class SuspiciousPastesTest < ActionDispatch::IntegrationTest
  setup do
    @paste = Paste.create!(
      content: "<title>Private marker</title><h1>Original content</h1>",
      original_filename: "original.html",
      custom_subdomain: "suspicious-test"
    )
  end

  test "flag blocks every public content route and alias without recording views" do
    @paste.update!(suspicious: true)

    assert_no_difference "PasteView.count" do
      public_urls.each do |url|
        get url
        assert_blocked

        head url
        assert_response :forbidden
        assert_empty response.body
      end
    end
  end

  test "flag overrides cached responses and clearing it restores the original content" do
    assert_not @paste.reload.suspicious?
    original_content = @paste.content
    original_updated_at = @paste.updated_at

    public_urls.each do |url|
      @paste.update_columns(suspicious: false)
      get url
      assert_response :success
      etag = response.headers.fetch("ETag")

      # Even a bulk flag update that leaves updated_at unchanged must block
      # revalidation instead of returning 304 for a previously cached document.
      @paste.update_columns(suspicious: true)
      get url, headers: { "If-None-Match" => etag }
      assert_blocked
    end

    @paste.update_columns(suspicious: false)
    get raw_paste_url(@paste, host: "www.example.com")
    assert_response :success
    assert_equal original_content, response.body
    assert_equal original_content, @paste.reload.content
    assert_equal original_updated_at, @paste.updated_at
  end

  test "flag overrides password unlock sessions and valid preview tokens" do
    @paste.update!(password: "sekret")
    post paste_password_url(@paste), params: { password: "sekret" }
    get paste_url(@paste)
    assert_response :success
    preview_url = css_select("iframe").first["src"]

    # Leave the password access version intact, so these credentials remain valid.
    @paste.update_columns(suspicious: true)
    get paste_url(@paste)
    assert_blocked
    get preview_url
    assert_blocked
  end

  test "owner access and web updates cannot clear the flag" do
    @paste.update!(user: users(:alice), password: "sekret", suspicious: true)
    post session_url, params: { email_address: users(:alice).email_address, password: "password" }

    get raw_paste_url(@paste)
    assert_blocked

    patch owned_paste_url(@paste), params: {
      suspicious: false,
      file: fixture_file_upload("hello.html", "text/html")
    }
    assert_response :see_other
    assert @paste.reload.suspicious?
    assert_includes @paste.content, "Hello from a fixture"
    get raw_paste_url(@paste)
    assert_blocked
  end

  test "API republishing cannot clear the flag" do
    @paste.update!(suspicious: true)

    patch api_paste_url(@paste, suspicious: false),
      params: "<h1>Republished</h1>",
      headers: { "Content-Type" => "text/html", "Authorization" => "Bearer #{@paste.update_token}" }

    assert_response :success
    assert @paste.reload.suspicious?
    assert_equal "<h1>Republished</h1>", @paste.content
    get raw_paste_url(@paste)
    assert_blocked
  end

  private
    def public_urls
      [ @paste.token, @paste.custom_subdomain ].flat_map do |identifier|
        [
          paste_url(identifier), raw_paste_url(identifier),
          render_paste_url(identifier), markdown_paste_url(identifier),
          "http://#{identifier}.example.com/"
        ]
      end
    end

    def assert_blocked
      assert_response :forbidden
      assert_equal "This paste is unavailable.", response.body
      assert_equal "text/plain", response.media_type
      assert_equal "no-store", response.headers["Cache-Control"]
      assert_nil response.headers["ETag"]
    end
end
