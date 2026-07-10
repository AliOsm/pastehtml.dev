module Oauth::AuthorizedApplicationsHelper
  # Host-only (never full URIs) parse of an application's possibly
  # whitespace-separated list of redirect URIs (Doorkeeper's own
  # RedirectUriValidator splits on any whitespace) -- the one client-
  # controlled value the OAuth flow actually verifies. Mirrors the consent
  # screen's redirect_host_html treatment of the same field.
  def redirect_hosts(application)
    application.redirect_uri.to_s.split.filter_map { |uri| URI.parse(uri).host }.uniq.join(", ")
  rescue URI::InvalidURIError
    application.redirect_uri
  end

  # Union of scopes granted across all of the user's active tokens for this
  # application, as human labels -- reuses the consent screen's
  # doorkeeper.scopes.* keys. `tokens_by_application_id` is the controller's
  # single grouped-tokens query (see Oauth::AuthorizedApplicationsController).
  def granted_scope_labels(application, tokens_by_application_id)
    tokens_for(application, tokens_by_application_id)
      .flat_map { |token| token.scopes.to_a }
      .uniq
      .map { |scope| t(scope, scope: [ :doorkeeper, :scopes ]) }
  end

  # Max last_used_at across the user's active tokens for this application, or
  # nil for a "never used" state (every token issued but never presented yet).
  def application_last_used_at(application, tokens_by_application_id)
    tokens_for(application, tokens_by_application_id).filter_map(&:last_used_at).max
  end

  private
    def tokens_for(application, tokens_by_application_id)
      tokens_by_application_id[application.id] || []
    end
end
