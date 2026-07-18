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
    recent_workers = @run.workers.order(started_at: :desc).limit(12).to_a
    workers = (@run.workers.where(status: "running").to_a + recent_workers).uniq
    @worker_activities = Orchestrator::WorkerActivity.for_workers(workers)
    @active_workers = @worker_activities.select { |activity| activity[:worker].status == "running" }
    @spawn_requests = SpawnRequest.open_only.where(run_id: @run.run_id).map { |request| JSON.parse(request.to_json) }
    @blocking_questions = @run.user_questions.open_only.where(priority: "blocking").order(:asked_at).to_a
    ticks = OrchestratorTick.for_run(@run.run_id).order(tick_count: :desc).limit(8).to_a.reverse
    @latest_tick = ticks.last && JSON.parse(ticks.last.to_json)
    @following_steps = Array(@latest_tick&.dig("followingSteps"))
    raw_events = BusEvent.where(run_id: @run.run_id).order(created_at: :desc).limit(20).to_a.reverse.map { |event| JSON.parse(event.to_json) }
    @timeline_events = build_timeline(raw_events).last(8).reverse
    @artifacts = collect_artifacts
    @planner_decisions = @run.planner_decisions.order(created_at: :desc).limit(5).to_a
    @latest_planner_decision = @planner_decisions.first
    @usage_summary = usage_summary
    @run_now = build_run_now
    @workspace_chat = current_workspace.workspace_chats.first_or_create!
    @workspace_chat_messages = @workspace_chat.messages.order(:created_at)
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

  def build_timeline(events)
    last_phase = nil

    events.each_with_object([]) do |event, timeline|
      case event["type"]
      when "run.status"
        phase = event.dig("payload", "phase")
        next if phase.blank? || phase == last_phase

        last_phase = phase
        timeline << event.merge("label" => "Run entered #{phase.tr('_', ' ')}")
      when "worker.spawned"
        timeline << event.merge("label" => "#{event.dig('payload', 'nickname')} started")
      when "worker.stopped"
        timeline << event.merge("label" => "#{event.dig('payload', 'nickname')} stopped")
      when "spawn_request.created"
        timeline << event.merge("label" => "#{event.dig('payload', 'requestedRole')} handoff requested")
      when "spawn_request.fulfilled"
        timeline << event.merge("label" => "Handoff assigned")
      end
    end
  end

  def build_run_now
    current_activity = @active_workers.max_by { |activity| activity[:last_activity_at] || activity[:started_at] || Time.at(0) }
    current_worker = current_activity&.dig(:worker)
    next_step = current_worker ? @following_steps.first : (@spawn_requests.first || @following_steps.first)
    attention_worker = @worker_activities.find { |activity| activity[:attention_needed] }
    state, detail, status_class =
      if current_worker
        [ "Work in progress", "#{current_worker.nickname} is working on #{current_worker.scope}.", "running" ]
      elsif @blocking_questions.any?
        [ "Needs your decision", "#{helpers.pluralize(@blocking_questions.count, "blocking question")} awaiting an answer.", "blocking" ]
      elsif @run.capacity_blocked?
        available_at = @run.capacity_available_at.in_time_zone
        [ "Waiting for capacity", "Work will resume automatically at #{helpers.l(available_at, format: "%H:%M %Z")}.", "planning" ]
      elsif @spawn_requests.any?
        [ "Ready to dispatch", "A #{@spawn_requests.first["requestedRole"]} handoff is waiting for the supervisor.", "planning" ]
      elsif @following_steps.any?
        [ "Awaiting the next plan", "The next planner turn will choose from the queued follow-up work.", "planning" ]
      elsif @run.phase == "planning"
        [ "Planning next step", @run.phase_summary.presence || "The orchestrator is deciding the next bounded handoff.", "planning" ]
      elsif attention_worker
        [ "Needs attention", "#{attention_worker[:worker].nickname} stopped unexpectedly.", "blocking" ]
      elsif @run.status == "completed"
        [ "Completed", "No further work is queued.", "completed" ]
      else
        [ "Monitoring", "No active worker or queued handoff is recorded yet.", "queued" ]
      end

    {
      state: state,
      detail: detail,
      status_class: status_class,
      why: current_worker&.reason.presence || @latest_tick&.dig("lastPlanSummary") || @run.phase_summary.presence,
      current_activity: current_activity,
      latest_activity_at: current_activity&.dig(:last_activity_at) || @run.phase_updated_at || @run.updated_at,
      next_step: next_step,
      latest_worker: @run.workers.where(status: "stopped").order(stopped_at: :desc).first
    }
  end

  def collect_artifacts
    artifact_names = (
      SpawnRequest.where(run_id: @run.run_id).pluck(:scope) +
      Array(@latest_tick&.dig("followingSteps")).map { |step| step["artifact"] || step[:artifact] } +
      [ "workflow-plan.md", "fix-summary.md", "verifier-report.md", "phone-speed-fix-summary.md", "phone-recording-report.md", "phone-verify-report.md" ]
    ).compact.uniq

    Orchestrator::ArtifactStore.collect(@run.target_root, @run.run_id, artifact_names)[:artifacts]
      .select { |artifact| artifact[:exists] }
      .map do |artifact|
        artifact.merge(content: Orchestrator::ArtifactStore.read(@run.target_root, @run.run_id, artifact[:name]).force_encoding("UTF-8").scrub)
      end
      .sort_by { |artifact| artifact[:updated_at] || "" }
      .reverse
      .first(4)
  rescue ArgumentError
    []
  end

  def usage_summary
    Orchestrator::RunUsage.build(@run)
  end
end
