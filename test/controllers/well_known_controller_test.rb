require "test_helper"

# RFC 9728 (protected resource metadata) + RFC 8414 (authorization server
# metadata) discovery documents. Both are static JSON derived exclusively
# from McpOauth::CONFIG -- never from request headers -- and must be
# reachable with no session, since MCP clients probe them before any login
# has happened.
class WellKnownControllerTest < ActionDispatch::IntegrationTest
  ISSUER = McpOauth::CONFIG[:issuer]

  test "protected resource metadata at the root well-known path" do
    get "/.well-known/oauth-protected-resource"

    assert_response :success
    assert_equal "application/json", response.media_type
    assert_equal expected_protected_resource_metadata, response.parsed_body
  end

  test "protected resource metadata at the mcp-suffixed well-known path" do
    get "/.well-known/oauth-protected-resource/mcp"

    assert_response :success
    assert_equal "application/json", response.media_type
    assert_equal expected_protected_resource_metadata, response.parsed_body
  end

  test "protected resource metadata is reachable with no session" do
    get "/.well-known/oauth-protected-resource"

    assert_response :success
    assert_nil session[:return_to_after_authenticating]
  end

  test "authorization server metadata returns all required fields" do
    get "/.well-known/oauth-authorization-server"

    assert_response :success
    assert_equal "application/json", response.media_type
    body = response.parsed_body

    assert_equal ISSUER, body["issuer"]
    assert_equal "#{ISSUER}/oauth/authorize", body["authorization_endpoint"]
    assert_equal "#{ISSUER}/oauth/token", body["token_endpoint"]
    assert_equal "#{ISSUER}/oauth/register", body["registration_endpoint"]
    assert_equal "#{ISSUER}/oauth/revoke", body["revocation_endpoint"]
    assert_equal %w[authorization_code refresh_token], body["grant_types_supported"]
    assert_equal %w[code], body["response_types_supported"]
    assert_equal %w[mcp:read mcp:pastes:write mcp:folders:write], body["scopes_supported"]
  end

  test "authorization server metadata advertises S256 PKCE support" do
    get "/.well-known/oauth-authorization-server"

    assert_equal [ "S256" ], response.parsed_body["code_challenge_methods_supported"]
  end

  test "authorization server metadata advertises no client authentication (public clients)" do
    get "/.well-known/oauth-authorization-server"

    assert_equal [ "none" ], response.parsed_body["token_endpoint_auth_methods_supported"]
  end

  test "authorization server metadata is reachable with no session" do
    get "/.well-known/oauth-authorization-server"

    assert_response :success
    assert_nil session[:return_to_after_authenticating]
  end

  # SEP-2127 MCP Server Card -- the static descriptor agents fetch before
  # opening an MCP connection. Public, cacheable, and built exclusively from
  # McpOauth::CONFIG like the other discovery documents.
  test "the server card returns the identity, transport, and contact fields" do
    get "/.well-known/mcp/server-card.json"

    assert_response :success
    assert_equal "application/json", response.media_type
    card = response.parsed_body

    assert_equal "dev.pastehtml/mcp", card["name"]
    assert_equal McpTools::SERVER_NAME, card["name"]
    assert card["description"].present?
    assert_equal McpTools::VERSION, card["version"]
    assert_equal "https://github.com/AliOsm/pastehtml.dev", card.dig("repository", "url")
    assert_equal ISSUER, card["websiteUrl"]
    assert_equal "mcp@pastehtml.dev", card.dig("maintainer", "email")
    assert card.dig("maintainer", "name").present?
  end

  test "the server card's remote entry names the /mcp endpoint and its protocol versions" do
    get "/.well-known/mcp/server-card.json"

    remote = response.parsed_body["remotes"].sole
    assert_equal McpOauth::CONFIG[:resource_uri], remote["url"]
    assert_equal "streamable-http", remote["type"]
    assert_equal "streamable-http", remote["transport"]
    assert_equal MCP::Configuration::SUPPORTED_STABLE_PROTOCOL_VERSIONS, remote["supportedProtocolVersions"]
    assert_includes remote["supportedProtocolVersions"], "2025-11-25"
  end

  test "the server card claims only the tools capability, matching the live server" do
    get "/.well-known/mcp/server-card.json"

    capabilities = response.parsed_body["capabilities"]
    assert_equal({ "listChanged" => false }, capabilities["tools"])
    assert_equal %w[tools], capabilities.keys
  end

  test "the server card is publicly cacheable for an hour and needs no session" do
    get "/.well-known/mcp/server-card.json"

    assert_includes response.headers["Cache-Control"], "public"
    assert_includes response.headers["Cache-Control"], "max-age=3600"
    assert_nil session[:return_to_after_authenticating]
  end

  # The experimental discovery contract (specVersion "draft"): the card is
  # ALSO reachable at <streamable-http-url>/server-card with its dedicated
  # media type, and a catalog at /.well-known/mcp/catalog.json points there.
  test "the card at /mcp/server-card carries the mcp-server-card media type and the same body" do
    get "/mcp/server-card"

    assert_response :success
    assert_equal "application/mcp-server-card+json", response.media_type
    # parsed_body only auto-parses registered JSON media types; parse by hand.
    card = JSON.parse(response.body)
    assert_equal McpTools::SERVER_NAME, card["name"]

    get "/.well-known/mcp/server-card.json"
    assert_equal response.parsed_body, card
  end

  # Validates the card against the upstream experimental ServerCard schema,
  # vendored at test/fixtures/files/server-card.schema.json (source:
  # modelcontextprotocol/experimental-ext-server-card schema.json, file sha
  # a93de9481e1a). Re-vendor and re-run when the extension stabilizes.
  test "the server card validates against the pinned upstream ServerCard schema" do
    get "/mcp/server-card"
    card = JSON.parse(response.body)

    schema_document = JSON.parse(file_fixture("server-card.schema.json").read)
    schemer = JSONSchemer.schema(schema_document.merge("$ref" => "#/$defs/ServerCard"))
    errors = schemer.validate(card).map { |error| error.fetch("error") }

    assert_empty errors, "server card does not conform to the pinned upstream schema"
    assert_equal "https://static.modelcontextprotocol.io/schemas/v1/server-card.schema.json", card["$schema"]
  end

  test "the catalog lists the server card with its identifier, media type, and URL" do
    get "/.well-known/mcp/catalog.json"

    assert_response :success
    assert_equal "application/json", response.media_type
    catalog = response.parsed_body

    assert_equal "draft", catalog["specVersion"]
    entry = catalog["entries"].sole
    assert_equal "urn:air:#{McpOauth::CONFIG[:host]}:mcp", entry["identifier"]
    assert_equal "PasteHTML", entry["displayName"]
    assert_equal "application/mcp-server-card+json", entry["mediaType"]
    assert_equal "#{ISSUER}/mcp/server-card", entry["url"]
  end

  test "the discovery endpoints answer cross-origin GETs (CORS)" do
    [ "/.well-known/mcp/catalog.json", "/mcp/server-card", "/.well-known/mcp/server-card.json" ].each do |path|
      get path

      assert_equal "*", response.headers["Access-Control-Allow-Origin"], path
      assert_equal "GET", response.headers["Access-Control-Allow-Methods"], path
      assert_equal "Content-Type", response.headers["Access-Control-Allow-Headers"], path
    end
  end

  test "every URL in the server card is issuer-derived or the public repository" do
    get "/.well-known/mcp/server-card.json"
    card = response.parsed_body

    urls = [ card["websiteUrl"], card.dig("repository", "url"), card.dig("maintainer", "url") ]
    urls += card["remotes"].map { |remote| remote["url"] }
    urls += card["icons"].map { |icon| icon["src"] }

    urls.each do |url|
      assert url.start_with?(ISSUER) || url.start_with?("https://github.com/AliOsm"),
             "unexpected URL origin in server card: #{url}"
    end
  end

  # CycloneDX SBOM -- generated into Rails.root by the Docker image build and
  # served through the controller so it gets its own (short) cache policy
  # instead of public/'s 1-year static-file header.
  test "the SBOM is served as cacheable JSON when the build generated one" do
    bom = { "bomFormat" => "CycloneDX", "specVersion" => "1.5", "version" => 1 }

    with_sbom_file(JSON.generate(bom)) do
      get "/.well-known/sbom.cdx.json"
    end

    assert_response :success
    assert_equal "application/json", response.media_type
    assert_equal bom, response.parsed_body
    assert_includes response.headers["Cache-Control"], "max-age=3600"
  end

  test "the SBOM path 404s when no BOM was generated (development, test)" do
    get "/.well-known/sbom.cdx.json"

    assert_response :not_found
  end

  test "every endpoint URL in both documents starts with the configured issuer" do
    get "/.well-known/oauth-protected-resource"
    prm = response.parsed_body
    assert prm["resource"].start_with?(ISSUER)
    prm["authorization_servers"].each { |url| assert url.start_with?(ISSUER) }

    get "/.well-known/oauth-authorization-server"
    asm = response.parsed_body
    %w[issuer authorization_endpoint token_endpoint registration_endpoint revocation_endpoint].each do |key|
      assert asm[key].start_with?(ISSUER), "expected #{key} (#{asm[key]}) to start with #{ISSUER}"
    end
  end

  private
    def with_sbom_file(content)
      Tempfile.create([ "sbom", ".cdx.json" ]) do |file|
        file.write(content)
        file.flush

        original = Rails.application.config.x.sbom_path
        Rails.application.config.x.sbom_path = Pathname.new(file.path)
        begin
          yield
        ensure
          Rails.application.config.x.sbom_path = original
        end
      end
    end

    def expected_protected_resource_metadata
      {
        "resource" => McpOauth::CONFIG[:resource_uri],
        "authorization_servers" => [ McpOauth::CONFIG[:issuer] ],
        "scopes_supported" => %w[mcp:read mcp:pastes:write mcp:folders:write],
        "bearer_methods_supported" => %w[header]
      }
    end
end
