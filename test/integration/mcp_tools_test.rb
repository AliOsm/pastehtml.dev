require "test_helper"

# Exercises the Phase 1 tools through the real /mcp endpoint with a real
# Doorkeeper token, proving the registry wiring: scope-filtered tools/list,
# structured tool results, and the controller's pre-dispatch write step-up.
class McpToolsIntegrationTest < ActionDispatch::IntegrationTest
  RESOURCE = McpOauth::CONFIG[:resource_uri]

  setup do
    @user = users(:alice)
    @application = oauth_applications(:mcp_client)
  end

  # --- tools/list is scope-filtered presentation ---------------------------

  test "a full-scope token lists all ten tools with annotations present" do
    mcp_post(tools_list_body, token: read_write_token.plaintext_token)

    assert_response :ok
    tools = response.parsed_body.dig("result", "tools")
    names = tools.map { |tool| tool["name"] }.sort
    assert_equal %w[
      configure_paste create_folder create_paste delete_folder get_paste
      get_paste_stats list_folders list_pastes rename_folder update_paste
    ], names

    create = tools.find { |tool| tool["name"] == "create_paste" }
    annotations = create.fetch("annotations")
    assert_equal false, annotations["readOnlyHint"]
    assert_equal false, annotations["destructiveHint"]
    assert_equal false, annotations["idempotentHint"]
    assert_equal false, annotations["openWorldHint"]
    assert create.key?("outputSchema"), "expected an output schema on the wire"

    read_tool = tools.find { |tool| tool["name"] == "list_pastes" }
    assert_equal true, read_tool.dig("annotations", "readOnlyHint")
    assert_equal true, read_tool.dig("annotations", "idempotentHint")

    update_tool = tools.find { |tool| tool["name"] == "update_paste" }
    assert_equal true, update_tool.dig("annotations", "destructiveHint"), "update_paste must be flagged destructive"

    delete_tool = tools.find { |tool| tool["name"] == "delete_folder" }
    assert_equal true, delete_tool.dig("annotations", "destructiveHint"), "delete_folder must be flagged destructive"
  end

  test "a read-only token lists exactly the four read tools" do
    mcp_post(tools_list_body, token: read_token.plaintext_token)

    assert_response :ok
    names = response.parsed_body.dig("result", "tools").map { |tool| tool["name"] }.sort
    assert_equal %w[ get_paste get_paste_stats list_folders list_pastes ], names
  end

  # --- tools/call -----------------------------------------------------------

  test "create_paste persists a paste owned by the token user and returns structuredContent" do
    assert_difference -> { @user.pastes.count }, 1 do
      mcp_post(
        tools_call_body("create_paste", content: "<title>Via MCP</title><p>hi</p>", format: "html"),
        token: read_write_token.plaintext_token
      )
    end

    assert_response :ok
    result = response.parsed_body["result"]
    structured = result["structuredContent"]
    assert structured.present?, "expected structuredContent on the result"

    paste = Paste.find_by(token: structured["token"])
    assert_equal @user, paste.user
    assert_equal "Via MCP", structured["title"]
    assert_not result["isError"]
  end

  test "create_paste with a read-only token is a 403 step-up at the HTTP layer" do
    assert_no_difference -> { Paste.count } do
      mcp_post(
        tools_call_body("create_paste", content: "<p>x</p>", format: "html"),
        token: read_token.plaintext_token
      )
    end

    assert_response :forbidden
    assert_equal "insufficient_scope", response.parsed_body["error"]
    # Union of the token's scopes and the missing one -- the unrelated
    # folders scope is not solicited.
    assert_includes response.headers["WWW-Authenticate"], %(scope="mcp:read mcp:pastes:write")
    assert_not_includes response.headers["WWW-Authenticate"], "mcp:folders:write"
  end

  test "a pastes-write token cannot create a folder through create_paste's folder_name side effect" do
    token = mint_token(scopes: "mcp:read mcp:pastes:write")

    assert_no_difference -> { Folder.count } do
      mcp_post(
        tools_call_body("create_paste", content: "<p>x</p>", format: "html", folder_name: "Sneaky Folder"),
        token: token.plaintext_token
      )
    end

    assert_response :ok
    result = response.parsed_body["result"]
    assert result["isError"], "expected a structured tool error, not a created folder"
    assert_equal "insufficient_scope", result.dig("structuredContent", "code")
  end

  test "list_pastes returns a schema-valid structured result through the server" do
    @user.pastes.create!(content: "<title>One</title>", original_filename: "p.html")

    mcp_post(tools_call_body("list_pastes"), token: read_token.plaintext_token)

    assert_response :ok
    result = response.parsed_body["result"]
    # A schema-invalid result would come back as a JSON-RPC error, not a result
    # with structuredContent -- so this also proves server-side output
    # validation accepts the computed content_bytes/timestamps.
    assert_not result["isError"]
    pastes = result.dig("structuredContent", "pastes")
    assert pastes.first["content_bytes"].is_a?(Integer)
    assert_equal 1, result.dig("structuredContent", "total_count")
  end

  test "update_paste republishes a user-owned paste's content through the real endpoint" do
    paste = @user.pastes.create!(content: "<title>Before</title><p>old</p>", original_filename: "paste.html")

    mcp_post(
      tools_call_body("update_paste", token: paste.token, content: "<title>After</title><p>new</p>", format: "html"),
      token: read_write_token.plaintext_token
    )

    assert_response :ok
    result = response.parsed_body["result"]
    assert_not result["isError"]
    assert_equal "After", result.dig("structuredContent", "title")
    assert_equal "<title>After</title><p>new</p>", paste.reload.content
  end

  test "list_folders returns a structured result for a read token" do
    @user.folders.create!(name: "Zeta")

    mcp_post(tools_call_body("list_folders"), token: read_token.plaintext_token)

    assert_response :ok
    folders = response.parsed_body.dig("result", "structuredContent", "folders")
    assert folders.any? { |folder| folder["name"] == "Zeta" }
  end

  private
    def mcp_post(body, token:)
      headers = {
        "Content-Type" => "application/json",
        "Accept" => "application/json, text/event-stream",
        "Authorization" => "Bearer #{token}"
      }
      post "/mcp", params: body, headers: headers
    end

    def mint_token(scopes:)
      Doorkeeper::AccessToken.create!(
        application: @application,
        resource_owner_id: @user.id,
        scopes: scopes,
        expires_in: 3600,
        resource: RESOURCE
      )
    end

    def read_write_token
      @read_write_token ||= mint_token(scopes: "mcp:read mcp:pastes:write mcp:folders:write")
    end

    def read_token
      @read_token ||= mint_token(scopes: "mcp:read")
    end

    def tools_list_body
      { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }.to_json
    end

    def tools_call_body(name, **arguments)
      { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: name, arguments: arguments } }.to_json
    end
end
