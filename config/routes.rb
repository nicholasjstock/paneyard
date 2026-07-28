Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "health#show", as: :rails_health_check

  # MCP endpoints worker/chaperone/planner-decision CLI subprocesses connect
  # to -- Streamable HTTP, hosted inside this already-running process rather
  # than spawned fresh per worker like the old scripts/workflow-mcp-server.ts
  # did. Each role gets its own scoped, tokenized server (app/services/
  # orchestrator/{worker,chaperone,planner_decision}_mcp_server.rb); there is
  # deliberately no unscoped bare /mcp endpoint anymore.
  mount Orchestrator::ChaperoneMcpEndpoint.new => "/mcp/chaperone"
  mount Orchestrator::ReplyReceivedMcpEndpoint.new => "/mcp/reply_received"
  mount Orchestrator::WorkerMcpEndpoint.new => "/mcp/worker"
  mount Orchestrator::PlannerDecisionMcpEndpoint.new => "/mcp/planner-decision"

  mount ActionCable.server => "/cable"

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "workspaces#index"

  resources :workspaces, only: %i[index show new create edit update destroy] do
    resource :project_setup, only: %i[create]

    resource :terminal_session, controller: "terminal_sessions", only: %i[show create destroy]

    resource :workspace_admin_chat, controller: "workspace_admin_chats", only: %i[update] do
      post :cancel
      post :reset
    end
    resources :workspace_admin_chat_messages, controller: "workspace_admin_chat_messages", only: %i[create]
    resources :runs, only: %i[index new create show] do
      member do
        post :stop
        post :switch_launcher
        post :retry_publication
      end
    end

    resources :workers, only: %i[index show] do
      member do
        post :stop
      end
    end

    resources :run_commands, only: [], param: :command_id do
      member do
        post :stop
      end
    end

    resources :questions, only: %i[index]

    resources :events, only: %i[index]
  end
end
