class RunsController < ApplicationController
  before_action :set_run, only: %i[show stop]

  def index
    @runs = Run.order(created_at: :desc)
  end

  def new
    @run = Run.new(launcher_variant: "claude")
    @workspaces = Workspace.order(:name)
  end

  def create
    @run = Run.new(run_params)
    @run.run_id = generate_run_id
    @run.status = "launching"
    @run.launched_by = current_operator

    workspace = Workspace.find_by(id: run_params[:workspace_id])
    @run.workspace = workspace
    @run.target_root = workspace&.root_path

    if @run.save
      LaunchRunJob.perform_later(@run.id)
      redirect_to run_path(@run), notice: "Launching #{@run.run_id}…"
    else
      @workspaces = Workspace.order(:name)
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @workers = Worker.where(run_id: @run.run_id).map { |worker| JSON.parse(worker.to_json) }
    @spawn_requests = SpawnRequest.open_only.where(run_id: @run.run_id).map { |request| JSON.parse(request.to_json) }
    ticks = OrchestratorTick.for_run(@run.run_id)
    @tick_history = { "runId" => @run.run_id, "entries" => ticks.map { |tick| JSON.parse(tick.to_json) } }
  end

  def stop
    StopRunJob.perform_later(@run.id)
    redirect_to run_path(@run), notice: "Stopping #{@run.run_id}…"
  end

  private

  def set_run
    @run = Run.find_by!(run_id: params[:id])
  end

  def run_params
    params.require(:run).permit(:task, :launcher_variant, :workspace_id)
  end

  def generate_run_id
    "demo-#{Time.current.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(2)}"
  end
end
