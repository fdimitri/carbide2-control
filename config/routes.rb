Rails.application.routes.draw do
  devise_for :users, defaults: { format: :json }, skip: %i[registrations passwords confirmations unlocks]

  namespace :api, defaults: { format: :json } do
    post '/login',  to: 'sessions#create'
    post '/signup', to: 'sessions#signup'
    delete '/logout', to: 'sessions#destroy'

    resources :projects, only: [:index, :show, :create, :destroy] do
      member do
        post :ws_token   # mint per-project JWT for workspace WS connect
      end
    end
  end

  get 'up' => 'rails/health#show', as: :rails_health_check
end
