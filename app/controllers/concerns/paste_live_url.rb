# Builds the per-paste origin URL (https://<subdomain>.pastehtml.dev/) from the
# current request, so it works across environments (token.localhost in dev).
module PasteLiveUrl
  def paste_live_url(paste, **query)
    # Downcased for legacy mixed-case tokens: hostnames are lowercased by
    # browsers anyway, and the live lookup is case-insensitive.
    url = "#{request.protocol}#{paste.public_subdomain.downcase}.#{request.domain}#{request.port_string}/"
    query = query.compact_blank

    query.present? ? "#{url}?#{query.to_query}" : url
  end
end
