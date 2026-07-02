require "test_helper"

module Api
  class PastesControllerTest < ActionDispatch::IntegrationTest
    test "publishes a multipart file upload" do
      assert_difference "Paste.count" do
        post api_pastes_url, params: { file: fixture_file_upload("hello.html", "text/html") }
      end

      assert_response :created
      body = response.parsed_body
      assert_equal 32, body["token"].length
      assert_equal 32, body["update_token"].length
      assert_equal "Hello", body["title"]
      assert_match %r{/p/#{body["token"]}\z}, body["url"]
      assert_equal "http://#{body["token"]}.example.com/", body["live_url"]
      assert_match %r{/p/#{body["token"]}/raw\z}, body["raw_url"]
      assert_match %r{/p/#{body["token"]}/render\z}, body["render_url"]
      assert_match %r{/p/#{body["token"]}/markdown\z}, body["markdown_url"]
    end

    test "publishes a raw html body with a filename param" do
      assert_difference "Paste.count" do
        post api_pastes_url(filename: "plan.html"),
          params: "<title>The Plan</title><h1>Plan</h1>",
          headers: { "Content-Type" => "text/html" }
      end

      assert_response :created
      body = response.parsed_body
      assert_equal "The Plan", body["title"]

      paste = Paste.find_by!(token: body["token"])
      assert_equal "plan.html", paste.original_filename
    end

    test "defaults the filename for raw bodies" do
      post api_pastes_url, params: "<p>Hi</p>", headers: { "Content-Type" => "text/html" }

      assert_response :created
      assert_equal "untitled.html", Paste.find_by!(token: response.parsed_body["token"]).original_filename
    end

    test "rejects an empty body with errors" do
      assert_no_difference "Paste.count" do
        post api_pastes_url
      end

      assert_response :unprocessable_entity
      assert response.parsed_body["errors"].any?
    end

    test "rejects a non-html filename" do
      post api_pastes_url(filename: "notes.txt"), params: "<p>Hi</p>", headers: { "Content-Type" => "text/html" }

      assert_response :unprocessable_entity
      assert(response.parsed_body["errors"].any? { |error| error.include?(".html") })
    end

    test "updates a paste with the bearer update token" do
      paste, update_token = publish("<title>v1</title>")

      patch api_paste_url(paste),
        params: "<title>v2</title><p>revised</p>",
        headers: { "Content-Type" => "text/html", "Authorization" => "Bearer #{update_token}" }

      assert_response :success
      assert_equal "v2", response.parsed_body["title"]
      assert_includes paste.reload.content, "revised"
    end

    test "rejects updates with a wrong or missing token" do
      paste, _update_token = publish("<title>v1</title>")

      patch api_paste_url(paste), params: "<p>nope</p>",
        headers: { "Content-Type" => "text/html", "Authorization" => "Bearer wrong" }
      assert_response :forbidden

      patch api_paste_url(paste), params: "<p>nope</p>", headers: { "Content-Type" => "text/html" }
      assert_response :forbidden

      assert_not_includes paste.reload.content, "nope"
    end

    test "rejects updates to pastes published before update tokens existed" do
      patch api_paste_url(pastes(:hello)), params: "<p>nope</p>",
        headers: { "Content-Type" => "text/html", "Authorization" => "Bearer anything" }

      assert_response :forbidden
    end

    test "responds 404 for updates to unknown pastes" do
      patch api_paste_url("missing"), params: "<p>hi</p>",
        headers: { "Content-Type" => "text/html", "Authorization" => "Bearer anything" }

      assert_response :not_found
    end

    test "rejects invalid update content" do
      paste, update_token = publish("<title>v1</title>")

      patch api_paste_url(paste), params: "",
        headers: { "Content-Type" => "text/html", "Authorization" => "Bearer #{update_token}" }

      assert_response :unprocessable_entity
      assert response.parsed_body["errors"].any?
    end

    test "does not require a csrf token" do
      with_forgery_protection do
        post api_pastes_url, params: "<p>Hi</p>", headers: { "Content-Type" => "text/html" }

        assert_response :created
      end
    end

    private
      def publish(content)
        post api_pastes_url, params: content, headers: { "Content-Type" => "text/html" }
        body = response.parsed_body
        [ Paste.find_by!(token: body["token"]), body["update_token"] ]
      end

      def with_forgery_protection
        original = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = true
        yield
      ensure
        ActionController::Base.allow_forgery_protection = original
      end
  end
end
