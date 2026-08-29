Rails.application.routes.draw do
  devise_for :users, defaults: { format: :json }, skip: %i[registrations passwords confirmations unlocks]

  # Public JWKS for workspace pods to verify control-minted tokens (ADR-015).
  get '/.well-known/jwks.json', to: 'well_known/jwks#show'

  namespace :api, defaults: { format: :json } do
    # Build/version provenance (public). `common` is the shape both the control
    # plane and the workspace server implement identically; `control` adds
    # control-only runtime detail. The client fetches these to fill in the SHAs
    # it cannot bake itself.
    namespace :v1 do
      get 'common/version',  to: 'version#common'
      get 'control/version', to: 'version#control'
      # Authenticated identity for THIS app's users table (control-local id).
      get 'control/me',      to: 'me#show'
    end

    post '/login',  to: 'sessions#create'
    post '/signup', to: 'sessions#signup'
    delete '/logout', to: 'sessions#destroy'

    # Available SPA client builds for the dashboard picker (public).
    resources :clients, only: [:index]

    resources :workspaces, only: [:index, :show, :create, :destroy] do
      member do
        post :token   # mint per-workspace JWT for workspace pod bootstrap
        get  :health  # active reachability probe (rails + worker WS)
      end
    end
  end

  get 'up' => 'rails/health#show', as: :rails_health_check

  # SPA fallback — must be LAST. Catches any other GET that wasn't matched
  # above (e.g. /login, /preferences) and returns the pinned dashboard build's
  # index.html so Vue Router's history mode can handle the route client-side.
  # Asset URLs under /assets/* and /clients/* are served by the static tier
  # before reaching here.
  get '*path', to: 'spa#show', constraints: ->(req) {
    !req.path.start_with?('/api', '/users', '/rails', '/assets', '/clients', '/up')
  }
  root to: 'spa#show'
end
