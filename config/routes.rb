Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "health#show", as: :rails_health_check

  # The MCP endpoint a run's interactive CLI session connects to --
  # Streamable HTTP, hosted inside this already-running process. Scoped and
  # tokenized per session (app/services/orchestrator/run_mcp_server.rb);
  # there is deliberately no unscoped bare /mcp endpoint.
  mount Orchestrator::RunMcpEndpoint.new => "/mcp/run"

  mount ActionCable.server => "/cable"

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "workspaces#index"

  resources :workspaces, only: %i[index show new create edit update destroy] do
    resource :workspace_admin_chat, controller: "workspace_admin_chats", only: %i[update] do
      post :cancel
      post :reset
    end
    resources :workspace_admin_chat_messages, controller: "workspace_admin_chat_messages", only: %i[create]
    resources :runs, only: %i[index new create show] do
      member do
        post :stop
        post :send_message
        post :remove_worktree
        post :close_session
      end
    end
  end
end
