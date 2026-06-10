# Builds the per-paste origin URL (https://<token>.pastehtml.dev/) from the
# current request, so it works across environments (token.localhost in dev).
module PasteLiveUrl
  def paste_live_url(paste)
    # Downcased for pre-launch mixed-case tokens: hostnames are lowercased by
    # browsers anyway, and the live lookup is case-insensitive.
    "#{request.protocol}#{paste.token.downcase}.#{request.domain}#{request.port_string}/"
  end
end
