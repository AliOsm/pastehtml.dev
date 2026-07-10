Rails.application.routes.draw do
  # Hosts like <token>.pastehtml.dev (32 lowercase alphanumerics) and user-selected
  # custom subdomains. Matched on the host so it works with any tld_length
  # (token.localhost in development).
  paste_host = lambda do |request|
    labels = request.host.to_s.downcase.split(".")
    subdomainish_host = labels.length >= 3 || (labels.last == "localhost" && labels.length >= 2)
    next false unless subdomainish_host

    Paste.hosted_subdomain?(labels.first)
  end

  # The project's vanity pages moved into the app (PagesController) but keep their
  # memorable <slug>.pastehtml.dev hosts, which now 301-redirect to the app path.
  vanity_subdomain = ->(request) { Paste::VANITY_PAGE_SUBDOMAINS.include?(request.host.to_s.downcase.split(".").first) }
  constraints vanity_subdomain do
    get "/", to: redirect(status: 301) { |_params, request|
      labels = request.host.split(".")
      host = labels.drop(1).join(".")
      port = request.standard_port? ? "" : ":#{request.port}"
      "#{request.protocol}#{host}#{port}/#{labels.first.downcase}"
    }
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

    # The project's own marketing/guide pages, rendered in the app layout.
    get "making-of", to: "pages#making_of", as: :making_of
    get "lock-it-up", to: "pages#lock_it_up", as: :lock_it_up
    get "mark-it-down", to: "pages#mark_it_down", as: :mark_it_down

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

    # OAuth authorization server for the MCP endpoint -- apex host ONLY (not
    # merely "any non-paste host"), so issuer, audience, and cookies collapse
    # to one canonical origin (prod: pastehtml.dev, dev: localhost, test:
    # www.example.com). The custom controllers layer mandatory RFC 8707
    # resource-indicator enforcement onto Doorkeeper's stock endpoints.
    # :applications is skipped (clients arrive via dynamic registration, not
    # an admin UI); :authorized_applications stays -- it's the "connected
    # agents" screen, restyled by its own controller/view like the
    # authorizations consent screen. /mcp itself and /oauth/register are
    # later tasks.
    constraints host: McpOauth::CONFIG[:host] do
      use_doorkeeper scope: "oauth" do
        controllers authorizations: "oauth/authorizations",
                    tokens: "oauth/tokens",
                    authorized_applications: "oauth/authorized_applications"
        skip_controllers :applications
      end

      # RFC 9728 protected resource metadata + RFC 8414 authorization server
      # metadata -- static discovery JSON MCP clients probe before any login.
      # The optional /mcp suffix matters: RFC 9728 derives a path-suffixed
      # metadata URL from a resource URL that has a path component, so a
      # client that builds the URL from McpOauth::CONFIG[:resource_uri]
      # (".../mcp") rather than following the WWW-Authenticate pointer asks
      # for that one.
      get ".well-known/oauth-protected-resource(/mcp)", to: "well_known#protected_resource"
      get ".well-known/oauth-authorization-server", to: "well_known#authorization_server"

      # RFC 7591 Dynamic Client Registration -- the PUBLIC, internet-facing
      # endpoint where MCP agents self-register before running the OAuth flow.
      # ActionController::API (no session, no CSRF): CLI clients POST bare JSON.
      post "oauth/register", to: "oauth/registrations#create"

      # The MCP Streamable HTTP endpoint. Routed for GET, POST, and DELETE (not
      # POST-only): the transport dispatches all three internally, and the
      # transports spec requires GET to receive an SSE stream or a 405 -- a
      # Rails routing 404 is neither. In stateless mode the transport produces
      # the compliant refusals itself.
      match "mcp", to: "mcp#handle", via: %i[get post delete]
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
