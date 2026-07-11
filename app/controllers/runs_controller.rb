class RunsController < ApplicationController
  before_action :require_workspace
  before_action :set_run, only: %i[show stop]

  def index
    @runs = current_workspace.runs.order(created_at: :desc)
  end

  def new
    @run = current_workspace.runs.new(launcher_variant: "claude")
  end

  def create
    @run = current_workspace.runs.new(run_params)
    @run.run_id = generate_run_id
    @run.status = "launching"
    @run.launched_by = current_operator
    @run.target_root = current_workspace.root_path

    if @run.save
      LaunchRunJob.perform_later(@run.id)
      redirect_to workspace_run_path(current_workspace, @run), notice: "Launching #{@run.run_id}…"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @workers = Worker.where(run_id: @run.run_id).map { |worker| JSON.parse(worker.to_json) }
    @active_workers = @workers.select { |worker| worker["status"] == "running" }
    @recent_workers = @workers.reject { |worker| worker["status"] == "running" }.last(3).reverse
    @spawn_requests = SpawnRequest.open_only.where(run_id: @run.run_id).map { |request| JSON.parse(request.to_json) }
    ticks = OrchestratorTick.for_run(@run.run_id)
    @latest_tick = ticks.last && JSON.parse(ticks.last.to_json)
    @following_steps = Array(@latest_tick&.dig("followingSteps"))
    @tick_history = { "runId" => @run.run_id, "entries" => ticks.map { |tick| JSON.parse(tick.to_json) } }
    raw_events = BusEvent.where(run_id: @run.run_id).order(created_at: :desc).limit(40).to_a.reverse.map { |event| JSON.parse(event.to_json) }
    @run_events = compress_events(raw_events).last(15)
    @signal_events = @run_events.reverse.reject { |event| event["type"] == "run.status" }.first(6)
    @artifact_previews = collect_artifact_previews
  end

  def stop
    StopRunJob.perform_now(@run.id)
    redirect_to workspace_run_path(current_workspace, @run), notice: "Stopping #{@run.run_id}…"
  end

  private

  def set_run
    @run = current_workspace.runs.find_by!(run_id: params[:id])
  end

  def run_params
    params.require(:run).permit(:task, :launcher_variant)
  end

  def generate_run_id
    "demo-#{Time.current.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(2)}"
  end

  def compress_events(events)
    events.each_with_object([]) do |event, compressed|
      previous = compressed.last
      if previous && duplicate_status_event?(previous, event)
        previous["repeatCount"] = previous.fetch("repeatCount", 1) + 1
        previous["at"] = event["at"]
      else
        compressed << event
      end
    end
  end

  def duplicate_status_event?(previous, current)
    previous["type"] == "run.status" &&
      current["type"] == "run.status" &&
      previous["payload"] == current["payload"]
  end

  def collect_artifact_previews
    artifact_names = (
      SpawnRequest.where(run_id: @run.run_id).pluck(:scope) +
      Array(@latest_tick&.dig("followingSteps")).map { |step| step["artifact"] || step[:artifact] } +
      [ "workflow-plan.md", "fix-summary.md", "verifier-report.md", "phone-speed-fix-summary.md", "phone-recording-report.md", "phone-verify-report.md" ]
    ).compact.uniq

    Orchestrator::ArtifactStore.collect(@run.target_root, @run.run_id, artifact_names)[:artifacts]
      .select { |artifact| artifact[:exists] }
      .map do |artifact|
        artifact.merge(preview: artifact[:preview].to_s.dup.force_encoding("UTF-8").scrub)
      end
      .sort_by { |artifact| artifact[:updated_at] || "" }
      .reverse
      .first(4)
  rescue ArgumentError
    []
  end
end
