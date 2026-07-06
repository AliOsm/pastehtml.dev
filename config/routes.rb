Rails.application.routes.draw do
  # Hosts like <token>.pastehtml.dev (32 lowercase alphanumerics), legacy vanity
  # hosts, and user-selected custom subdomains. Matched on the host so it works
  # with any tld_length (token.localhost in development).
  paste_host = lambda do |request|
    labels = request.host.to_s.downcase.split(".")
    subdomainish_host = labels.length >= 3 || (labels.last == "localhost" && labels.length >= 2)
    next false unless subdomainish_host

    Paste.hosted_subdomain?(labels.first)
  end

  # Each paste is served from its own origin so documents get real, isolated
  # localStorage (no CSP sandbox needed: the separate origin is the isolation).
  constraints paste_host do
    get "/", to: "pastes#live", as: :live_paste_root
    post "/", to: "paste_passwords#create", as: :live_paste_password
  end

  # Everything else exists only on the app's own hosts -- paste origins serve
  # nothing but their document/password gate, so untrusted content can't frame
  # the app's UI under its origin or reach the API from there.
  constraints ->(request) { !paste_host.call(request) } do
    # Dynamic PWA files rendered from app/views/pwa/*. They live at stable root
    # paths because a service worker's scope is bound to its path.
    get "manifest.json" => "pwa#manifest", as: :pwa_manifest
    get "service-worker.js" => "rails/pwa#service_worker", as: :pwa_service_worker

    root "pastes#new"

    resource :session, only: %i[ new create destroy ]
    resources :users, only: %i[ new create ]
    resources :api_keys, only: %i[ index create destroy ]

    # Saves the visitor's language choice (from the header toggle) and bounces
    # back. Unknown locales are ignored in the controller, so it stays a plain
    # GET link without a route constraint.
    get "locale/:locale", to: "locales#update", as: :locale

    resources :folders
    resources :pastes, only: %i[ index create ]
    get "pastes/:token/edit", to: "pastes#edit", as: :edit_owned_paste
    patch "pastes/:token", to: "pastes#update", as: :owned_paste

    namespace :api do
      resources :folders, only: %i[ index create ]
      resources :pastes, only: %i[ create update ], param: :token
    end
    get "p/:token", to: "pastes#show", as: :paste
    get "p/:token/password", to: "paste_passwords#new", as: :paste_password
    post "p/:token/password", to: "paste_passwords#create"
    get "p/:token/raw", to: "pastes#raw", as: :raw_paste
    get "p/:token/render", to: "pastes#rendered", as: :render_paste
    get "p/:token/markdown", to: "pastes#markdown", as: :markdown_paste
  end

  # Reveal health status on /up that returns 200 if the app boots without
  # exceptions, otherwise 500. Outside the host constraints so monitoring works
  # however it reaches the app.
  get "up" => "rails/health#show", as: :rails_health_check

  # Browsers probe /favicon.ico automatically, including on isolated paste
  # origins where the app intentionally exposes almost no routes. Return a
  # quiet empty response so paste documents do not create console 404s.
  get "favicon.ico", to: ->(_env) { [ 204, { "Content-Type" => "image/x-icon" }, [] ] }
end
