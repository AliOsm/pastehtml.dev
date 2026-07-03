require "test_helper"

class PastesControllerTest < ActionDispatch::IntegrationTest
  test "root shows the upload page" do
    get root_url

    assert_response :success
    assert_select "form[action=?]", pastes_path
    assert_select "input[type=file]"
  end

  test "agents can discover the integration guide" do
    get root_url
    assert_includes response.body, "Hey beautiful agent!"
    assert_select "a[href='/llms.txt']"

    get "/llms.txt"
    assert_response :success
    assert_includes response.body, "update_token"
    assert_includes response.body, "Agent etiquette"
  end

  test "root carries seo meta tags and the og image" do
    get root_url

    assert_select "title", "Share HTML in seconds — pastehtml.dev"
    assert_select "link[rel=canonical][href=?]", root_url
    assert_select "meta[property='og:image'][content=?]", "http://www.example.com/og-image.png"
    assert_select "meta[name='twitter:card'][content='summary_large_image']"
    assert_select "link[rel=manifest][href=?]", pwa_manifest_path
  end

  test "creating a paste from an html file redirects to its page" do
    assert_difference "Paste.count" do
      post pastes_url, params: { file: fixture_file_upload("hello.html", "text/html") }
    end

    token = @response.redirect_url[%r{/p/([a-z0-9]+)\z}, 1]
    paste = Paste.find_by!(token:)
    assert_equal "hello.html", paste.original_filename
    assert_includes paste.content, "Hello from a fixture"
  end

  test "rejects a missing file" do
    assert_no_difference "Paste.count" do
      post pastes_url
    end

    assert_redirected_to root_url
    assert_equal "Choose an HTML file to upload.", flash[:alert]
  end

  test "rejects a non-html file" do
    assert_no_difference "Paste.count" do
      post pastes_url, params: { file: fixture_file_upload("notes.txt", "text/plain") }
    end

    assert_redirected_to root_url
    assert_match(/must be an .html or .htm file/, flash[:alert])
  end

  test "show displays the share link, preview and source" do
    paste = pastes(:hello)

    get paste_url(paste)

    assert_response :success
    assert_select "iframe[src=?]:not([sandbox])", "http://#{paste.token}.example.com/"
    assert_select "input[value=?]", "http://#{paste.token}.example.com/"
    assert_includes response.headers["X-Robots-Tag"], "noindex"
    assert_select "title", "hello.html — pastehtml.dev"
    assert_select "meta[name=robots][content*=noindex]"
  end

  test "show highlights the source without leaking unescaped html" do
    paste = Paste.create!(content: "<script>alert('xss')</script>", original_filename: "evil.html")

    get paste_url(paste)

    assert_response :success
    assert_select "#panel-source code.highlight span", minimum: 1
    assert_not_includes response.body, "<script>alert"
  end

  test "show offers an in-site fullscreen preview" do
    get paste_url(pastes(:hello))

    assert_select "[data-controller=fullscreen] iframe"
    assert_select "button[data-action='fullscreen#toggle']"
    assert_select "[data-action*='keydown.f@window->fullscreen#keyToggle']"
  end

  test "show responds 404 for unknown tokens" do
    get paste_url("nonexistent-token")

    assert_response :not_found
  end

  test "render serves the html verbatim inside a csp sandbox" do
    paste = pastes(:hello)

    get render_paste_url(paste)

    assert_response :success
    assert_equal paste.content, response.body
    assert_equal "text/html; charset=utf-8", response.headers["Content-Type"]
    assert_includes response.headers["Content-Security-Policy"], "sandbox"
    assert_not_includes response.headers["Content-Security-Policy"], "allow-same-origin"
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
  end

  test "raw serves the html verbatim as plain text" do
    paste = pastes(:hello)

    get raw_paste_url(paste)

    assert_response :success
    assert_equal paste.content, response.body
    assert_equal "text/plain; charset=utf-8", response.headers["Content-Type"]
    assert_nil response.headers["Content-Security-Policy"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_includes response.headers["X-Robots-Tag"], "noindex"
  end

  test "raw responds 404 for unknown tokens" do
    get raw_paste_url("nonexistent-token")

    assert_response :not_found
  end

  test "markdown serves the paste converted to markdown" do
    paste = Paste.create!(content: "<h1>Heading</h1><p>Some <em>prose</em>.</p>", original_filename: "doc.html")

    get markdown_paste_url(paste)

    assert_response :success
    assert_equal "text/markdown; charset=utf-8", response.headers["Content-Type"]
    assert_includes response.body, "# Heading"
    assert_includes response.body, "_prose_"
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_includes response.headers["X-Robots-Tag"], "noindex"
  end

  test "markdown revalidates by etag instead of caching by age" do
    paste = pastes(:hello)

    get markdown_paste_url(paste)
    assert_not_includes response.headers["Cache-Control"], "max-age=31556952"
    etag = response.headers["ETag"]
    assert etag.present?

    get markdown_paste_url(paste), headers: { "If-None-Match" => etag }
    assert_response :not_modified
  end

  test "markdown responds 404 for unknown tokens" do
    get markdown_paste_url("nonexistent-token")

    assert_response :not_found
  end

  test "serves the paste from its own origin without a csp sandbox" do
    paste = pastes(:hello)

    get "http://#{paste.token}.example.com/"

    assert_response :success
    assert_equal paste.content, response.body
    assert_equal "text/html; charset=utf-8", response.headers["Content-Type"]
    assert_nil response.headers["Content-Security-Policy"]
    assert_equal "no-referrer", response.headers["Referrer-Policy"]
    assert_includes response.headers["X-Robots-Tag"], "noindex"
    assert response.headers["ETag"].present?
  end

  test "serves legacy mixed-case tokens from their lowercased subdomain" do
    paste = pastes(:hello)
    Paste.where(id: paste.id).update_all(token: "3yZe7vAqK9mNpXs2Wb4cRd8fGh1jTuVw")

    get "http://3yze7vaqk9mnpxs2wb4crd8fgh1jtuvw.example.com/"

    assert_response :success
    assert_equal paste.content, response.body
  end

  test "live responses revalidate by etag" do
    paste = pastes(:hello)

    get "http://#{paste.token}.example.com/"
    etag = response.headers["ETag"]
    assert etag.present?
    assert_not_includes response.headers["Cache-Control"].to_s, "max-age=31556952"

    get "http://#{paste.token}.example.com/", headers: { "If-None-Match" => etag }
    assert_response :not_modified
  end

  test "paste origins serve only their document" do
    paste = pastes(:hello)

    get "http://#{paste.token}.example.com/p/#{pastes(:snippet).token}"
    assert_response :not_found

    post "http://#{paste.token}.example.com/api/pastes",
      params: "<p>hi</p>", headers: { "Content-Type" => "text/html" }
    assert_response :not_found

    get "http://#{paste.token}.example.com/manifest.json"
    assert_response :not_found
  end

  test "web publishing never reveals an update token" do
    post pastes_url, params: { file: fixture_file_upload("hello.html", "text/html") }

    follow_redirect!
    assert_response :success
    paste = Paste.find_by!(token: request.path[%r{/p/([a-z0-9]+)}, 1])
    assert_not_includes response.body, paste.update_token_digest
  end

  test "unknown token subdomains respond 404" do
    get "http://#{"z" * 32}.example.com/"

    assert_response :not_found
  end

  test "non-token subdomains fall through to the app" do
    get "http://www.example.com/"

    assert_response :success
    assert_select "h1", /Share HTML/
  end

  test "raw revalidates by etag instead of caching by age" do
    paste = pastes(:hello)

    get raw_paste_url(paste)
    assert_not_includes response.headers["Cache-Control"], "max-age=31556952"
    etag = response.headers["ETag"]
    assert etag.present?

    get raw_paste_url(paste), headers: { "If-None-Match" => etag }
    assert_response :not_modified
  end

  test "the web ui exposes no update or delete routes" do
    paste = pastes(:hello)

    patch "/p/#{paste.token}"
    assert_response :not_found

    delete "/p/#{paste.token}"
    assert_response :not_found
  end
end
