Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # MCP endpoint worker/planner CLI subprocesses connect to (see
  # app/services/orchestrator/mcp_server.rb, app/mcp_tools/) -- Streamable
  # HTTP, hosted inside this already-running process rather than spawned
  # fresh per worker like the old scripts/workflow-mcp-server.ts did.
  mcp_transport = MCP::Server::Transports::StreamableHTTPTransport.new(Orchestrator::McpServer.build)
  mount mcp_transport => "/mcp"

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

  resources :workspaces, only: %i[index new create destroy]

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
end
