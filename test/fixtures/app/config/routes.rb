Rails.application.routes.draw do
  devise_for :users, controllers: { sessions: "users/sessions" }
  root to: "posts#index"
  resources :posts, only: %i[index show] do
    member { post :publish }
  end
  namespace :admin do
    resources :reports, only: [:index]
  end
end
