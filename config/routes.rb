Rails.application.routes.draw do
  # Hosts like <token>.pastehtml.dev (32 lowercase alphanumerics), plus a few
  # curated vanity subdomains for the blog posts. Matched on the host so it
  # works with any tld_length (token.localhost in development).
  vanity_hosts = %w[ making-of lock-it-up mark-it-down ]
  paste_host = /\A(?:[a-z0-9]{32}|#{Regexp.union(vanity_hosts).source})\./

  # Each paste is served from its own origin so documents get real, isolated
  # localStorage (no CSP sandbox needed: the separate origin is the isolation).
  constraints ->(request) { request.host.match?(paste_host) } do
    get "/", to: "pastes#live", as: :live_paste_root
  end

  # Everything else exists only on the app's own hosts -- paste origins serve
  # nothing but their document, so untrusted content can't frame the app's UI
  # under its origin or reach the API from there.
  constraints ->(request) { !request.host.match?(paste_host) } do
    # Dynamic PWA files rendered from app/views/pwa/*. They live at stable root
    # paths because a service worker's scope is bound to its path.
    get "manifest.json" => "pwa#manifest", as: :pwa_manifest
    get "service-worker.js" => "rails/pwa#service_worker", as: :pwa_service_worker

    root "pastes#new"

    # Saves the visitor's language choice (from the header toggle) and bounces
    # back. Unknown locales are ignored in the controller, so it stays a plain
    # GET link without a route constraint.
    get "locale/:locale", to: "locales#update", as: :locale

    resources :pastes, only: :create

    namespace :api do
      resources :pastes, only: %i[ create update ], param: :token
    end
    get "p/:token", to: "pastes#show", as: :paste
    get "p/:token/raw", to: "pastes#raw", as: :raw_paste
    get "p/:token/render", to: "pastes#rendered", as: :render_paste
    get "p/:token/markdown", to: "pastes#markdown", as: :markdown_paste
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  # Outside the host constraints so monitoring works however it reaches the app.
  get "up" => "rails/health#show", as: :rails_health_check
end
