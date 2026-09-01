Rails.application.routes.draw do
  # Authentication. The generator supplies sign-in/out and password reset;
  # registration is ours.
  resource :registration, only: [ :new, :create ]
  resource :session, only: [ :new, :create, :destroy ]
  resources :passwords, param: :token

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # The feed is the whole application for now.
  resources :posts, only: [ :index, :show, :create, :edit, :update, :destroy ] do
    resource :like, only: [ :create, :destroy ]
    resource :repost, only: [ :create, :destroy ]
    resources :replies, only: [ :create ], controller: "replies"
  end

  # Public profiles. The @ is literal — /@ada — so a profile URL reads the way
  # the handle is written everywhere else.
  get "@:username", to: "profiles#show", as: :profile,
      constraints: { username: User::USERNAME_ROUTE_CONSTRAINT }

  # Editing your own profile. Singular and id-less on purpose: the resource is
  # whoever is signed in, so a route to anyone else's profile settings does not
  # exist, rather than existing and needing a guard (F-4.5).
  get   "profile/edit", to: "profiles#edit",   as: :edit_profile
  patch "profile",      to: "profiles#update", as: :update_profile

  resource :search, only: [ :show ], controller: "search"

  resources :tags, only: [ :show ], param: :name

  root "posts#index"
end
