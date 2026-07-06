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

    test "renders a raw markdown body sent as text/markdown" do
      assert_difference "Paste.count" do
        post api_pastes_url, params: "# Hello\n\nBody **text**.",
          headers: { "Content-Type" => "text/markdown" }
      end

      assert_response :created
      body = response.parsed_body
      assert_equal "Hello", body["title"]

      paste = Paste.find_by!(token: body["token"])
      assert_equal "untitled.md", paste.original_filename
      assert_includes paste.content, 'class="md-body"'
      assert_includes paste.content, "<strong>text</strong>"
    end

    test "renders a multipart markdown upload by its .md filename" do
      post api_pastes_url, params: { file: fixture_file_upload("sample.md", "text/markdown") }

      assert_response :created
      body = response.parsed_body
      assert_equal "Sample Doc", body["title"]

      paste = Paste.find_by!(token: body["token"])
      assert_equal "sample.md", paste.original_filename
      assert_includes paste.content, '<pre class="mermaid">'
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

    test "publishes into the api key owner's account and creates a requested folder" do
      assert_difference "Paste.count", 1 do
        assert_difference -> { users(:alice).folders.count }, 1 do
          post api_pastes_url(folder_name: "Agent Plans", custom_subdomain: "agent-plan"),
            params: "<title>Agent Plan</title><h1>Plan</h1>",
            headers: { "Content-Type" => "text/html", "Authorization" => "Bearer #{alice_agent_key}" }
        end
      end

      assert_response :created
      body = response.parsed_body
      paste = Paste.find_by!(token: body["token"])

      assert_equal users(:alice), paste.user
      assert_equal "Agent Plans", paste.folder.name
      assert_equal "agent-plan", paste.custom_subdomain
      assert_equal true, body["account_paste"]
      assert_nil body["update_token"]
      assert_equal users(:alice).id, body.dig("owner", "id")
      assert_equal "Agent Plans", body.dig("folder", "name")
      assert_predicate api_keys(:alice_agent).reload.last_used_at, :present?
    end

    test "folder scoped api keys publish into their configured folder by default" do
      post api_pastes_url,
        params: "<title>Scoped</title><p>Saved to projects</p>",
        headers: { "Content-Type" => "text/html", "X-PasteHTML-API-Key" => alice_projects_key }

      assert_response :created
      paste = Paste.find_by!(token: response.parsed_body["token"])
      assert_equal users(:alice), paste.user
      assert_equal folders(:projects), paste.folder
      assert_equal "Projects", response.parsed_body.dig("folder", "name")
    end

    test "folder scoped api keys cannot be redirected to a different folder" do
      assert_no_difference "Paste.count" do
        post api_pastes_url(folder_name: "Other"),
          params: "<p>Nope</p>",
          headers: { "Content-Type" => "text/html", "Authorization" => "Bearer #{alice_projects_key}" }
      end

      assert_response :unprocessable_entity
      assert_includes response.parsed_body["errors"].join, "scoped"
    end

    test "folder assignment requires an account api key" do
      assert_no_difference "Paste.count" do
        post api_pastes_url(folder_name: "No account"),
          params: "<p>Nope</p>",
          headers: { "Content-Type" => "text/html" }
      end

      assert_response :unauthorized
      assert_includes response.parsed_body["error"], "API key"
    end

    test "anonymous callers cannot claim a custom subdomain" do
      assert_no_difference "Paste.count" do
        post api_pastes_url(custom_subdomain: "squatted"),
          params: "<p>Nope</p>",
          headers: { "Content-Type" => "text/html" }
      end

      assert_response :unauthorized
      assert_includes response.parsed_body["error"], "custom_subdomain"
    end

    test "rejects invalid account api keys before creating a paste" do
      assert_no_difference "Paste.count" do
        post api_pastes_url,
          params: "<p>Nope</p>",
          headers: { "Content-Type" => "text/html", "Authorization" => "Bearer pht_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC" }
      end

      assert_response :unauthorized
    end

    test "rejects malformed bearer account api keys instead of falling back to anonymous publishing" do
      assert_no_difference "Paste.count" do
        post api_pastes_url,
          params: "<p>Nope</p>",
          headers: { "Content-Type" => "text/html", "Authorization" => "Bearer pht_invalid" }
      end

      assert_response :unauthorized
    end


    test "invalid account publishes do not leave behind newly requested folders" do
      assert_no_difference "Paste.count" do
        assert_no_difference -> { users(:alice).folders.where(name: "Ghost Folder").count } do
          post api_pastes_url(folder_name: "Ghost Folder", filename: "notes.txt"),
            params: "<p>Nope</p>",
            headers: { "Content-Type" => "text/html", "Authorization" => "Bearer #{alice_agent_key}" }
        end
      end

      assert_response :unprocessable_entity
      assert response.parsed_body["errors"].any?
    end

    test "rejects malformed folder ids without casting them to another folder" do
      assert_no_difference "Paste.count" do
        post api_pastes_url(folder_id: "#{folders(:projects).id}abc"),
          params: "<p>Nope</p>",
          headers: { "Content-Type" => "text/html", "Authorization" => "Bearer #{alice_agent_key}" }
      end

      assert_response :unprocessable_entity
      assert_includes response.parsed_body["errors"].join, "Folder not found"
    end

    test "account api keys update only pastes owned by their user" do
      owned = Paste.create!(content: "<title>Before</title>", original_filename: "owned.html", user: users(:alice))

      patch api_paste_url(owned),
        params: "<title>After</title><p>Owned update</p>",
        headers: { "Content-Type" => "text/html", "Authorization" => "Bearer #{alice_agent_key}" }

      assert_response :success
      assert_equal "After", response.parsed_body["title"]
      assert_includes owned.reload.content, "Owned update"

      patch api_paste_url(pastes(:snippet)),
        params: "<p>stolen</p>",
        headers: { "Content-Type" => "text/html", "Authorization" => "Bearer #{alice_agent_key}" }

      assert_response :forbidden
      assert_not_includes pastes(:snippet).reload.content, "stolen"
    end


    test "folder scoped api keys update only pastes inside their configured folder" do
      inside = Paste.create!(content: "<title>Before</title>", original_filename: "inside.html", user: users(:alice), folder: folders(:projects))
      outside = Paste.create!(content: "<title>Outside</title>", original_filename: "outside.html", user: users(:alice))

      patch api_paste_url(inside),
        params: "<title>Inside after</title>",
        headers: { "Content-Type" => "text/html", "X-PasteHTML-API-Key" => alice_projects_key }

      assert_response :success
      assert_equal "Inside after", inside.reload.title

      patch api_paste_url(outside),
        params: "<title>Outside after</title>",
        headers: { "Content-Type" => "text/html", "X-PasteHTML-API-Key" => alice_projects_key }

      assert_response :forbidden
      assert_equal "Outside", outside.reload.title
    end

    test "account api keys can claim anonymous pastes when the update token is supplied separately" do
      paste, update_token = publish("<title>Anonymous</title>")

      patch api_paste_url(paste),
        params: { folder_name: "Claimed" },
        headers: { "Authorization" => "Bearer #{alice_agent_key}", "X-Update-Token" => update_token }

      assert_response :success
      paste.reload
      assert_equal users(:alice), paste.user
      assert_equal "Claimed", paste.folder.name
      assert_equal "Claimed", response.parsed_body.dig("folder", "name")
    end

    test "unscoped account keys cannot file a paste into another user's folder by id" do
      assert_no_difference "Paste.count" do
        post api_pastes_url(folder_id: folders(:bob_notes).id),
          params: "<p>Nope</p>",
          headers: { "Content-Type" => "text/html", "Authorization" => "Bearer #{alice_agent_key}" }
      end

      assert_response :unprocessable_entity
      assert_includes response.parsed_body["errors"].join, "Folder not found"
    end

    test "unscoped account keys reject a folder_id and folder_name that disagree" do
      assert_no_difference "Paste.count" do
        post api_pastes_url(folder_id: folders(:projects).id, folder_name: "Different"),
          params: "<p>Nope</p>",
          headers: { "Content-Type" => "text/html", "Authorization" => "Bearer #{alice_agent_key}" }
      end

      assert_response :unprocessable_entity
      assert_includes response.parsed_body["errors"].join, "do not refer to the same folder"
    end

    test "folder scoped keys accept a redundant folder_id that matches their scope" do
      post api_pastes_url(folder_id: folders(:projects).id),
        params: "<title>Scoped by id</title>",
        headers: { "Content-Type" => "text/html", "X-PasteHTML-API-Key" => alice_projects_key }

      assert_response :created
      assert_equal folders(:projects), Paste.find_by!(token: response.parsed_body["token"]).folder
    end

    test "folder scoped keys accept a folder_name that matches their scope case-insensitively" do
      post api_pastes_url(folder_name: "projects"),
        params: "<title>Scoped by name</title>",
        headers: { "Content-Type" => "text/html", "X-PasteHTML-API-Key" => alice_projects_key }

      assert_response :created
      assert_equal folders(:projects), Paste.find_by!(token: response.parsed_body["token"]).folder
    end

    test "folder scoped keys cannot detach a paste from their scope with clear_folder" do
      assert_no_difference "Paste.count" do
        post api_pastes_url(clear_folder: "true"),
          params: "<p>Nope</p>",
          headers: { "Content-Type" => "text/html", "X-PasteHTML-API-Key" => alice_projects_key }
      end

      assert_response :unprocessable_entity
      assert_includes response.parsed_body["errors"].join, "scoped to a different folder"
    end

    test "a leaked update token stops working once the paste is claimed into an account" do
      paste, update_token = publish("<title>Anonymous</title>")

      patch api_paste_url(paste),
        params: { folder_name: "Claimed" },
        headers: { "Authorization" => "Bearer #{alice_agent_key}", "X-Update-Token" => update_token }
      assert_response :success
      assert_equal users(:alice), paste.reload.user

      # The anonymous token must no longer authorize updates on its own.
      patch api_paste_url(paste),
        params: "<title>Hijacked</title>",
        headers: { "Content-Type" => "text/html", "X-Update-Token" => update_token }

      assert_response :forbidden
      assert_not_includes paste.reload.content, "Hijacked"
    end

    private
      def alice_agent_key
        "pht_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      end

      def alice_projects_key
        "pht_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
      end

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
