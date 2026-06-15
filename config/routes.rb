Rails.application.routes.draw do
  root "batches#index"

  resources :reviews, only: %i[index new create show]
  resources :batches, only: %i[index new create show]

  # Reveal health status on /up that returns 200 if the app boots with no exceptions.
  get "up" => "rails/health#show", as: :rails_health_check
end
