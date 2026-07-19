Rails.application.routes.draw do
  devise_for :users, defaults: { format: :json }, skip: %i[registrations passwords confirmations unlocks]

  namespace :api, defaults: { format: :json } do
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
