# Hand-rolled RFC 8707 (Resource Indicators) enforcement -- Doorkeeper has no
# native support. The MCP spec requires audience-bound tokens, and this
# authorization server exists solely for the MCP endpoint, so both OAuth
# endpoints demand EXACTLY ONE `resource` parameter naming it, except that the
# token endpoint may allow refresh grants to omit it and inherit the resource
# already bound to the refresh token:
#
# - Missing values are rejected unless a controller explicitly allows them;
#   repeated and array-style values always fail with RFC 8707 `invalid_target`.
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
        return if supplied.empty? && allow_omitted_resource_indicator?
        return if supplied.length == 1 && canonical_resource?(supplied.first)

        reject_invalid_target
      end

      # Authorization requests and authorization-code exchanges require an
      # explicit resource. The token controller overrides this narrowly for
      # compatible refresh-token requests.
      def allow_omitted_resource_indicator?
        false
      end

      # Rails params collapse repeated keys (`resource=a&resource=b` becomes
      # just "b"), which would let a doubled parameter slip through looking
      # valid. Rack::Utils.parse_query keeps repeats as arrays, so parse the
      # raw query string and form body instead. `resource[]=...` array params
      # arrive under the raw key "resource[]" and therefore count as zero
      # `resource` values, rejecting that shape too.
      def raw_resource_values
        raw_parameter_values("resource")
      end

      def raw_resource_parameter_omitted?
        raw_parameter_sets.none? do |parameters|
          parameters.keys.any? { |key| key == "resource" || key.start_with?("resource[") }
        end
      end

      def raw_parameter_values(name)
        raw_parameter_sets.flat_map { |parameters| Array(parameters[name]) }
      end

      def raw_parameter_sets
        @raw_parameter_sets ||= [ request.query_string, url_encoded_body ].map do |raw|
          Rack::Utils.parse_query(raw.to_s)
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
