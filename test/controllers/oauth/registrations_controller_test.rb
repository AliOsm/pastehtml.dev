require "test_helper"

# RFC 7591 Dynamic Client Registration -- POST /oauth/register. This endpoint
# is PUBLIC and internet-facing: coding agents (Claude Code, Codex CLI, ...)
# self-register here before running the OAuth flow, so the metadata contract is
# validated strictly rather than echoed. Every client minted here is a public
# client (confidential: false) that never holds a secret.
class Oauth::RegistrationsControllerTest < ActionDispatch::IntegrationTest
  NORMALIZED_SCOPE = "mcp:read mcp:pastes:write mcp:folders:write".freeze

  # --- Happy path -----------------------------------------------------------

  test "minimal registration mints a public dynamic client" do
    assert_difference -> { Doorkeeper::Application.count }, 1 do
      register(redirect_uris: [ "http://127.0.0.1:49321/callback" ])
    end

    assert_response :created
    assert_equal "application/json", response.media_type
    body = response.parsed_body

    assert body["client_id"].present?
    assert_kind_of Integer, body["client_id_issued_at"]
    assert body["client_name"].present?
    assert_equal [ "http://127.0.0.1:49321/callback" ], body["redirect_uris"]
    assert_equal %w[authorization_code refresh_token], body["grant_types"]
    assert_equal %w[code], body["response_types"]
    assert_equal NORMALIZED_SCOPE, body["scope"]
  end

  test "response advertises token_endpoint_auth_method none and never a secret" do
    register(redirect_uris: [ "http://127.0.0.1:49321/callback" ])

    body = response.parsed_body
    assert_equal "none", body["token_endpoint_auth_method"]
    assert_not body.key?("client_secret"), "registration response must never carry a client_secret"
  end

  test "registration sends no-store and pragma cache headers" do
    register(redirect_uris: [ "http://127.0.0.1:49321/callback" ])

    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-cache", response.headers["Pragma"]
  end

  test "persisted record is a secretless public dynamic client with the full scope" do
    register(redirect_uris: [ "http://127.0.0.1:49321/callback" ])

    application = Doorkeeper::Application.find_by(uid: response.parsed_body["client_id"])
    assert_equal false, application.confidential
    assert_nil application.secret
    assert_equal true, application.dynamic
    assert_equal NORMALIZED_SCOPE, application.scopes.to_s
    assert_equal "http://127.0.0.1:49321/callback", application.redirect_uri
  end

  test "client_id_issued_at matches the record creation time" do
    register(redirect_uris: [ "http://127.0.0.1:49321/callback" ])

    application = Doorkeeper::Application.find_by(uid: response.parsed_body["client_id"])
    assert_equal application.created_at.to_i, response.parsed_body["client_id_issued_at"]
  end

  # --- Acceptance edge cases ------------------------------------------------

  test "accepts loopback http on localhost, 127.0.0.1 and [::1] with odd ports" do
    %w[
      http://localhost:1/callback
      http://127.0.0.1:65535/cb
      http://[::1]:8912/callback
    ].each do |uri|
      register(redirect_uris: [ uri ])
      assert_response :created, "expected #{uri} to be accepted"
      assert_equal [ uri ], response.parsed_body["redirect_uris"]
    end
  end

  test "accepts an exact https redirect uri on any host" do
    register(redirect_uris: [ "https://codex.example.com/oauth/callback" ])

    assert_response :created
    assert_equal [ "https://codex.example.com/oauth/callback" ], response.parsed_body["redirect_uris"]
  end

  test "accepts multiple redirect uris" do
    uris = [ "http://127.0.0.1:1234/cb", "http://localhost:5678/cb" ]
    register(redirect_uris: uris)

    assert_response :created
    assert_equal uris, response.parsed_body["redirect_uris"]
    application = Doorkeeper::Application.find_by(uid: response.parsed_body["client_id"])
    assert_equal uris.join("\n"), application.redirect_uri
  end

  test "requested scope subset is persisted and returned as the full allowed set" do
    register(redirect_uris: [ "http://127.0.0.1:49321/callback" ], scope: "mcp:read")

    assert_response :created
    assert_equal NORMALIZED_SCOPE, response.parsed_body["scope"]
    application = Doorkeeper::Application.find_by(uid: response.parsed_body["client_id"])
    assert_equal NORMALIZED_SCOPE, application.scopes.to_s
  end

  test "a single split write scope is a valid requested subset" do
    register(redirect_uris: [ "http://127.0.0.1:49321/callback" ], scope: "mcp:pastes:write")

    assert_response :created
    assert_equal NORMALIZED_SCOPE, response.parsed_body["scope"]
  end

  test "the retired mcp:write spelling is rejected like any unknown scope" do
    register(redirect_uris: [ "http://127.0.0.1:49321/callback" ], scope: "mcp:read mcp:write")

    assert_response :bad_request
    assert_equal "invalid_client_metadata", response.parsed_body["error"]
  end

  test "a supplied grant_types subset is normalized to the full pair" do
    register(redirect_uris: [ "http://127.0.0.1:49321/callback" ], grant_types: [ "authorization_code" ])

    assert_response :created
    assert_equal %w[authorization_code refresh_token], response.parsed_body["grant_types"]
  end

  test "an explicit token_endpoint_auth_method none is accepted" do
    register(redirect_uris: [ "http://127.0.0.1:49321/callback" ], token_endpoint_auth_method: "none")

    assert_response :created
  end

  test "a supplied client_name is stored and echoed" do
    register(redirect_uris: [ "http://127.0.0.1:49321/callback" ], client_name: "  Claude Code  ")

    assert_response :created
    assert_equal "Claude Code", response.parsed_body["client_name"]
  end

  test "unknown metadata fields are silently ignored" do
    register(
      redirect_uris: [ "http://127.0.0.1:49321/callback" ],
      logo_uri: "https://example.com/logo.png",
      software_id: "whatever"
    )

    assert_response :created
    assert_not response.parsed_body.key?("logo_uri")
  end

  # --- Redirect URI rejections (invalid_redirect_uri) -----------------------

  test "rejects a missing redirect_uris field" do
    assert_no_difference -> { Doorkeeper::Application.count } do
      register({})
    end
    assert_invalid_redirect_uri
  end

  test "rejects an empty redirect_uris array" do
    register(redirect_uris: [])
    assert_invalid_redirect_uri
  end

  test "rejects a non-array redirect_uris value" do
    register(redirect_uris: "http://127.0.0.1:1234/cb")
    assert_invalid_redirect_uri
  end

  test "rejects more than ten redirect uris" do
    uris = Array.new(11) { |i| "http://127.0.0.1:#{4000 + i}/cb" }
    register(redirect_uris: uris)
    assert_invalid_redirect_uri
  end

  test "rejects a redirect uri with a fragment" do
    register(redirect_uris: [ "https://example.com/cb#section" ])
    assert_invalid_redirect_uri
  end

  test "rejects a redirect uri with userinfo" do
    register(redirect_uris: [ "https://user:pass@example.com/cb" ])
    assert_invalid_redirect_uri
  end

  test "rejects duplicate redirect uris" do
    register(redirect_uris: [ "http://127.0.0.1:1234/cb", "http://127.0.0.1:1234/cb" ])
    assert_invalid_redirect_uri
  end

  test "rejects non-loopback http" do
    register(redirect_uris: [ "http://example.com/cb" ])
    assert_invalid_redirect_uri
  end

  test "rejects a garbage redirect uri" do
    register(redirect_uris: [ "not a uri" ])
    assert_invalid_redirect_uri
  end

  test "rejects a relative redirect uri" do
    register(redirect_uris: [ "/callback" ])
    assert_invalid_redirect_uri
  end

  test "rejects a malformed port" do
    register(redirect_uris: [ "http://127.0.0.1:notaport/cb" ])
    assert_invalid_redirect_uri
  end

  test "rejects a numeric but out-of-range port" do
    # URI.parse happily accepts :99999 (> 65535); the controller must not.
    register(redirect_uris: [ "http://127.0.0.1:99999/callback" ])
    assert_invalid_redirect_uri
  end

  test "rejects a redirect uri longer than the per-uri cap" do
    long_uri = "https://example.com/#{"a" * Oauth::RegistrationsController::MAX_REDIRECT_URI_LENGTH}"
    register(redirect_uris: [ long_uri ])
    assert_invalid_redirect_uri
  end

  # --- Metadata rejections (invalid_client_metadata) ------------------------

  test "rejects a non-none token_endpoint_auth_method" do
    register(redirect_uris: [ "http://127.0.0.1:1234/cb" ], token_endpoint_auth_method: "client_secret_basic")
    assert_invalid_client_metadata
  end

  test "rejects an unknown grant_type" do
    register(redirect_uris: [ "http://127.0.0.1:1234/cb" ], grant_types: [ "client_credentials" ])
    assert_invalid_client_metadata
  end

  test "rejects response_types other than code" do
    register(redirect_uris: [ "http://127.0.0.1:1234/cb" ], response_types: [ "token" ])
    assert_invalid_client_metadata
  end

  test "rejects an unknown scope" do
    register(redirect_uris: [ "http://127.0.0.1:1234/cb" ], scope: "mcp:read admin")
    assert_invalid_client_metadata
  end

  test "rejects an over-long client_name" do
    register(redirect_uris: [ "http://127.0.0.1:1234/cb" ], client_name: "a" * 256)
    assert_invalid_client_metadata
  end

  test "validation failures never create an application" do
    assert_no_difference -> { Doorkeeper::Application.count } do
      register(redirect_uris: [ "http://example.com/cb" ])
      register(redirect_uris: [ "http://127.0.0.1:1234/cb" ], scope: "admin")
    end
  end

  # --- Kill switch ----------------------------------------------------------

  test "kill switch returns 403 before any validation" do
    with_registration_disabled do
      assert_no_difference -> { Doorkeeper::Application.count } do
        # Deliberately invalid body -- the kill switch must fire first.
        register(redirect_uris: [ "http://example.com/cb" ])
      end
    end

    assert_response :forbidden
    assert_equal "registration_disabled", response.parsed_body["error"]
  end

  # --- Rate limit -----------------------------------------------------------

  test "the eleventh registration from one IP is rate limited" do
    # The test env's cache is a null_store (increment always returns nil), so
    # give the rate limiter a real counter on the exact store object the
    # rate_limit macro captured at class load, exercising the throttle
    # end-to-end without touching production behavior.
    with_counting_cache_store do
      10.times do |i|
        register(redirect_uris: [ "http://127.0.0.1:49321/callback" ])
        assert_response :created, "request #{i + 1} should be allowed"
      end

      register(redirect_uris: [ "http://127.0.0.1:49321/callback" ])
      assert_response :too_many_requests
      assert_equal "too_many_requests", response.parsed_body["error"]
    end
  end

  private
    def register(metadata)
      post "/oauth/register", params: metadata, as: :json
    end

    def assert_invalid_redirect_uri
      assert_response :bad_request
      body = response.parsed_body
      assert_equal "invalid_redirect_uri", body["error"]
      assert body["error_description"].present?
    end

    def assert_invalid_client_metadata
      assert_response :bad_request
      body = response.parsed_body
      assert_equal "invalid_client_metadata", body["error"]
      assert body["error_description"].present?
    end

    def with_registration_disabled
      original = ENV["MCP_DYNAMIC_REGISTRATION_DISABLED"]
      ENV["MCP_DYNAMIC_REGISTRATION_DISABLED"] = "true"
      yield
    ensure
      ENV["MCP_DYNAMIC_REGISTRATION_DISABLED"] = original
    end

    def with_counting_cache_store
      store = Oauth::RegistrationsController.cache_store
      counts = Hash.new(0)
      store.define_singleton_method(:increment) do |key, amount = 1, **_opts|
        counts[key] += amount
      end
      yield
    ensure
      store.singleton_class.remove_method(:increment)
    end
end
