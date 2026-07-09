Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "runs#index"

  resources :runs, only: %i[index new create show] do
    member do
      post :stop
    end
  end

  resources :workers, only: %i[index show] do
    member do
      post :stop
    end
  end

  resources :questions, only: %i[index] do
    member do
      post :answer
    end
  end

  resources :events, only: %i[index]

  namespace :api do
    resources :spawn_requests, only: %i[index create] do
      member do
        post :fulfill
        post :dismiss
      end
    end

    resources :user_questions, only: %i[index create] do
      member do
        post :answer
      end
    end

    resources :workers, only: %i[index create] do
      member do
        post :stop
      end
    end

    resources :orchestrator_ticks, only: %i[create] do
      collection do
        get :latest
        get :history
      end
    end

    # Not modeled as a RESTful resource(s) block: there's no per-record :id
    # in the URL (the target Run is always identified by runId in the
    # request body/query, matching WorkflowBus#publishRunStatus /
    # #listRunStatuses on the TS side) and "list across all runs" +
    # "publish one run's status" don't share a natural singular/plural
    # resource shape.
    get "run_statuses", to: "run_statuses#index"
    patch "run_status", to: "run_statuses#update"

    resources :events, only: %i[index]
  end
end
