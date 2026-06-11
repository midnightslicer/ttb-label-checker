Rails.application.routes.draw do
  root "batches#index"

  # Authentication
  get    "login"  => "sessions#new",     as: :login
  post   "login"  => "sessions#create"
  delete "logout" => "sessions#destroy", as: :logout

  resources :reviews, only: %i[new create show]
  resources :batches, only: %i[index new create show]

  # Reveal health status on /up that returns 200 if the app boots with no exceptions.
  get "up" => "rails/health#show", as: :rails_health_check
end
