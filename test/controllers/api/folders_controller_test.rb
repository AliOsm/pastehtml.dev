require "test_helper"

module Api
  class FoldersControllerTest < ActionDispatch::IntegrationTest
    ALICE_AGENT_KEY = "pht_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    test "lists folders for the account api key owner" do
      get api_folders_url, headers: { "Authorization" => "Bearer #{ALICE_AGENT_KEY}" }

      assert_response :success
      names = response.parsed_body.fetch("folders").map { |folder| folder.fetch("name") }
      assert_includes names, "Projects"
      assert_predicate api_keys(:alice_agent).reload.last_used_at, :present?
    end

    test "creates folders for the account api key owner" do
      assert_difference -> { users(:alice).folders.count } do
        post api_folders_url,
          params: { folder: { name: "Agent Inbox" } },
          headers: { "Authorization" => "Bearer #{ALICE_AGENT_KEY}" }
      end

      assert_response :created
      assert_equal "Agent Inbox", response.parsed_body.dig("folder", "name")
      assert_equal users(:alice), Folder.order(:created_at).last.user
    end


    test "creates folders from a top-level name for simple agent clients" do
      assert_difference -> { users(:alice).folders.count } do
        post api_folders_url,
          params: { name: "Top Level Inbox" },
          headers: { "Authorization" => "Bearer #{ALICE_AGENT_KEY}" }
      end

      assert_response :created
      assert_equal "Top Level Inbox", response.parsed_body.dig("folder", "name")
      assert_equal users(:alice), Folder.order(:created_at).last.user
    end

    test "folder scoped api keys only list their scoped folder" do
      users(:alice).folders.create!(name: "Private")

      get api_folders_url,
        headers: { "Authorization" => "Bearer pht_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" }

      assert_response :success
      assert_equal [ "Projects" ], response.parsed_body.fetch("folders").map { |folder| folder.fetch("name") }
    end

    test "folder scoped api keys cannot create folders" do
      assert_no_difference -> { users(:alice).folders.count } do
        post api_folders_url,
          params: { name: "Out of scope" },
          headers: { "Authorization" => "Bearer pht_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" }
      end

      assert_response :forbidden
      assert_includes response.parsed_body.fetch("error"), "scoped"
    end

    test "requires a valid account api key" do
      get api_folders_url
      assert_response :unauthorized

      get api_folders_url, headers: { "Authorization" => "Bearer pht_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC" }
      assert_response :unauthorized
    end
  end
end
