# Hand-rolled RFC 8707 (Resource Indicators) enforcement -- Doorkeeper has no
# native support. The MCP spec requires audience-bound tokens, and this
# authorization server exists solely for the MCP endpoint, so both OAuth
# endpoints demand EXACTLY ONE `resource` parameter naming it:
#
# - Missing, repeated, or array-style `resource` values are rejected with the
#   RFC 8707 `invalid_target` error (each controller renders its own shape).
# - The comparison follows RFC 3986 semantics: scheme and host are
#   case-insensitive, the path is byte-exact. `HTTPS://HOST/mcp` passes,
#   `/MCP` fails.
# - Callers persist only the canonical McpOauth::CONFIG[:resource_uri] --
#   never the client's spelling -- so the /mcp audience check can compare
#   byte-exactly against stored values.
module Oauth
  module ResourceIndicatorEnforcement
    private
      def enforce_resource_indicator
        supplied = raw_resource_values
        return if supplied.length == 1 && canonical_resource?(supplied.first)

        reject_invalid_target
      end

      # Rails params collapse repeated keys (`resource=a&resource=b` becomes
      # just "b"), which would let a doubled parameter slip through looking
      # valid. Rack::Utils.parse_query keeps repeats as arrays, so parse the
      # raw query string and form body instead. `resource[]=...` array params
      # arrive under the raw key "resource[]" and therefore count as zero
      # `resource` values, rejecting that shape too.
      def raw_resource_values
        [ request.query_string, url_encoded_body ].flat_map do |raw|
          Array(Rack::Utils.parse_query(raw.to_s)["resource"])
        end
      end

      def url_encoded_body
        # OAuth requests are application/x-www-form-urlencoded (RFC 6749);
        # anything else (e.g. multipart) contributes no resource values and
        # fails the exactly-one requirement.
        return "" unless request.media_type == "application/x-www-form-urlencoded"

        # raw_post caches the body and rewinds the input, so the params
        # parsing that Doorkeeper relies on still sees the full body.
        request.raw_post
      end

      def canonical_resource?(value)
        supplied = URI.parse(value.to_s)
        canonical = URI.parse(McpOauth::CONFIG[:resource_uri])

        supplied.scheme.to_s.casecmp?(canonical.scheme) &&
          supplied.host.to_s.casecmp?(canonical.host) &&
          supplied.port == canonical.port &&
          supplied.path == canonical.path &&
          supplied.query.nil? &&
          supplied.fragment.nil? &&
          supplied.userinfo.nil?
      rescue URI::InvalidURIError
        false
      end
  end
end
