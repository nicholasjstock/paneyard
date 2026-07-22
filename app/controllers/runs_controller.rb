class RunsController < ApplicationController
  before_action :require_workspace
  before_action :require_initialized_workspace, only: %i[new create]
  before_action :set_run, only: %i[show stop switch_launcher retry_publication]

  def index
    @runs = current_workspace.runs.order(created_at: :desc)
  end

  def new
    @run = current_workspace.runs.new(launcher_variant: "claude")
  end

  def create
    @run = current_workspace.runs.new(run_params)
    @run.run_id = generate_run_id
    @run.worktree_name = Orchestrator::GitWorktree.name_for(@run)
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
    @chaperone_reviews = @run.chaperone_reviews.order(created_at: :desc).to_a
    attach_chaperone_reviews
    @active_workers = @worker_activities.select { |activity| activity[:worker].status == "running" }
    @spawn_requests = SpawnRequest.open_only.where(run_id: @run.run_id).map { |request| JSON.parse(request.to_json) }
    @blocking_questions = @run.user_questions.open_only.where(priority: "blocking").order(:asked_at).to_a
    ticks = OrchestratorTick.for_run(@run.run_id).order(tick_count: :desc).limit(8).to_a.reverse
    @latest_tick = ticks.last && JSON.parse(ticks.last.to_json)
    @following_steps = Array(@latest_tick&.dig("followingSteps"))
    raw_events = BusEvent.where(run_id: @run.run_id).order(created_at: :desc).limit(20).to_a.reverse.map { |event| JSON.parse(event.to_json) }
    @timeline_events = build_timeline(raw_events).last(8).reverse
    @artifacts = collect_artifacts
    @planner_decisions = @run.planner_decisions.includes(:spawn_request, :attempts).order(created_at: :desc).to_a
    @acceptance_criteria = @run.acceptance_criteria.roots.includes(:children).to_a
    @criterion_worker_groups = Orchestrator::AcceptanceCriteriaWorkers.group(run_id: @run.run_id, activities: @worker_activities)
    @latest_planner_decision = @planner_decisions.first
    @usage_summary = usage_summary
    @run_now = build_run_now
    @activity_feed = build_activity_feed
    @workspace_chat = current_workspace.workspace_chats.first_or_create!
    @workspace_chat_messages = @workspace_chat.messages.order(:created_at)
    @run_commands = @run.run_commands.order(started_at: :desc, created_at: :desc).limit(20).to_a
  end

  def stop
    StopRunJob.perform_now(@run.id)
    redirect_to workspace_run_path(current_workspace, @run), notice: "Stopping #{@run.run_id}…"
  end

  def switch_launcher
    target = params.require(:launcher_variant)
    Orchestrator::SwitchRunLauncher.call(run: @run, launcher_variant: target)
    redirect_to workspace_run_path(current_workspace, @run), notice: "Switched to #{target.capitalize} and resumed queued work."
  rescue Orchestrator::SwitchRunLauncher::Ineligible, ActionController::ParameterMissing => error
    redirect_to workspace_run_path(current_workspace, @run), alert: error.message
  end

  def retry_publication
    unless @run.publication_retryable?
      redirect_to workspace_run_path(current_workspace, @run), alert: "This run is not awaiting PR publication retry."
      return
    end

    @run.update!(status: "running", publication_status: "queued", publication_error: nil)
    FinalizeRunPublicationJob.perform_later(@run.id)
    redirect_to workspace_run_path(current_workspace, @run), notice: "Retrying PR publication…"
  end

  private

  # StepPolicy fails closed (protects everything) until a workspace has
  # declared its own protected paths (Workspace#initialized?), so no real
  # task run may launch before that -- the bootstrap run that does the
  # declaring is created separately, via Orchestrator::WorkspaceInit, not
  # through this controller.
  def require_initialized_workspace
    return if current_workspace.initialized?

    redirect_to workspace_runs_path(current_workspace),
      alert: "This workspace is still initializing (discovering its dev environment and protected paths). " \
        "Wait for that run to finish before launching a new one."
  end

  def set_run
    @run = current_workspace.runs.find_by!(run_id: params[:id])
  end

  def run_params
    params.require(:run).permit(:task, :launcher_variant)
  end

  def generate_run_id
    "run-#{Time.current.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(2)}"
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
      when "worker.handoff_rejected"
        timeline << event.merge("label" => "Handoff rejected: #{event.dig('payload', 'error')}")
      end
    end
  end

  def build_run_now
    current_activity = @active_workers.max_by { |activity| activity[:last_activity_at] || activity[:started_at] || Time.at(0) }
    current_worker = current_activity&.dig(:worker)
    narrative_activity = current_activity || @worker_activities.max_by { |activity| activity[:last_activity_at] || Time.at(0) }
    next_step = current_worker ? @following_steps.first : (@spawn_requests.first || @following_steps.first)
    attention_worker = @worker_activities.find { |activity| activity[:attention_needed] }
    latest_worker = @run.workers.where(status: "stopped").order(stopped_at: :desc).first
    state, detail, why, next_action, operator_action, status_class =
      if @run.status == "failed"
        [
          "Run failed",
          @run.phase_summary.presence || "The run stopped after an orchestration failure.",
          attention_worker&.dig(:worker)&.stop_reason.presence || "The orchestrator cannot safely continue from the current state.",
          "No automatic retry is scheduled.",
          "Review the failure, then restart or launch a replacement run.",
          "blocking"
        ]
      elsif @blocking_questions.any?
        question = @blocking_questions.first
        [
          "Your decision is needed",
          "The run is paused on #{helpers.pluralize(@blocking_questions.count, 'blocking question')}.",
          question.text,
          "Answer the question below to resume orchestration.",
          "Answer required before work can continue.",
          "blocking"
        ]
      elsif @run.status == "stopped"
        [
          "Run stopped",
          @run.phase_summary.presence || "This run is no longer being monitored.",
          latest_worker&.stop_reason.presence || "The run was stopped before completion.",
          "No further work will start automatically.",
          "Launch a new run if you want to continue this objective.",
          "queued"
        ]
      elsif @run.status == "completed"
        [
          "Run completed",
          "The acceptance contract is complete and no work remains queued.",
          @run.phase_summary.presence || "The orchestrator accepted the final evidence.",
          "No further work is scheduled.",
          "No action required.",
          "completed"
        ]
      elsif @run.launch_queued?
        [
          "Launch is queued",
          "The launch job has not started.",
          "No healthy background worker has claimed the launch yet.",
          "Start bin/dev; the queued launch will then be claimed automatically.",
          "Start bin/dev to continue.",
          "blocking"
        ]
      elsif current_worker
        [
          "Work in progress",
          current_activity[:latest_progress].presence || "#{current_worker.nickname} is working on #{current_worker.scope}.",
          current_worker.reason.presence || @run.phase_summary.presence || "The current plan assigned this worker.",
          next_step_description(next_step, fallback: "The planner will evaluate the worker's handoff when it finishes."),
          "No action required while the worker is making progress.",
          "running"
        ]
      elsif @run.capacity_blocked?
        available_at = @run.capacity_available_at.in_time_zone
        [
          "Waiting for capacity",
          "The next model call is paused until #{helpers.l(available_at, format: '%H:%M %Z')}.",
          @run.phase_summary.presence || "The model provider rejected the previous attempt because capacity was unavailable.",
          "Rails will retry the open handoff automatically when capacity returns.",
          "No action required.",
          "planning"
        ]
      elsif attention_worker
        worker = attention_worker[:worker]
        [
          "Worker needs attention",
          "#{worker.nickname} stopped before completing its handoff.",
          worker.stop_reason.presence || "The worker process exited unexpectedly.",
          @spawn_requests.any? ? "A recovery handoff is queued." : "The orchestrator will request a recovery decision.",
          "No action required unless recovery also fails.",
          "blocking"
        ]
      elsif @spawn_requests.any?
        request = @spawn_requests.first
        [
          "Ready to dispatch",
          "A #{request['requestedRole']} handoff is queued for #{request['scope']}.",
          request["text"].presence || @run.phase_summary.presence || "The planner selected the next bounded step.",
          "Rails will claim the request and start its worker automatically.",
          "No action required.",
          "planning"
        ]
      elsif @following_steps.any?
        [
          "Awaiting the next plan",
          "The previous step finished and follow-up work remains.",
          @run.phase_summary.presence || "The run has a validated continuation queue.",
          next_step_description(@following_steps.first, fallback: "The next planner turn will select the handoff."),
          "No action required.",
          "planning"
        ]
      elsif @run.phase == "planning"
        [
          "Planning next step",
          @run.phase_summary.presence || "The orchestrator is deciding the next bounded handoff.",
          @latest_tick&.dig("lastPlanSummary").presence || "Current run evidence is being reduced into one decision.",
          "The planner will either queue one worker, request context, or ask for your decision.",
          "No action required.",
          "planning"
        ]
      else
        [
          "Monitoring",
          "No active worker or queued handoff is recorded yet.",
          @run.phase_summary.presence || "The recurring orchestrator tick is watching this run.",
          "The next tick will either dispatch work or report why it cannot.",
          "No action required yet.",
          "queued"
        ]
      end

    {
      state: state,
      detail: detail,
      status_class: status_class,
      badge_label: run_badge_label(state),
      why: why,
      next: next_action,
      operator_action: operator_action,
      operator_action_required: state.in?([ "Run failed", "Your decision is needed", "Launch is queued" ]),
      current_activity: current_activity,
      narrative_activity: narrative_activity,
      latest_activity_at: current_activity&.dig(:last_activity_at) || @run.phase_updated_at || @run.updated_at,
      next_step: next_step,
      latest_worker: latest_worker,
      plan: @latest_planner_decision&.decision
    }
  end

  def run_badge_label(state)
    {
      "Run failed" => "failed",
      "Your decision is needed" => "action required",
      "Run stopped" => "stopped",
      "Run completed" => "complete",
      "Launch is queued" => "queued",
      "Work in progress" => "active",
      "Waiting for capacity" => "auto retry",
      "Worker needs attention" => "recovering",
      "Ready to dispatch" => "queued",
      "Awaiting the next plan" => "planning",
      "Planning next step" => "planning",
      "Monitoring" => "monitoring"
    }.fetch(state)
  end

  def next_step_description(step, fallback:)
    return fallback unless step.present?

    owner = step["requestedRole"] || step[:owner] || step["owner"]
    scope = step["scope"] || step[:artifact] || step["artifact"]
    instruction = step["text"] || step[:success_check] || step["successCheck"]
    summary = [ owner, scope ].compact.join(" will handle ")
    [ summary.presence, instruction.presence ].compact.join(": ").presence || fallback
  end

  def build_activity_feed
    event_items = @timeline_events.filter_map do |event|
      next if event["type"].in?(%w[spawn_request.created spawn_request.fulfilled])
      next unless activity_event_visible?(event)

      {
        actor: activity_event_actor(event), label: event["label"],
        at: Time.iso8601(event["at"]), kind: "event"
      }
    rescue ArgumentError
      nil
    end
    worker_items = @worker_activities.filter_map do |activity|
      next unless activity[:latest_progress].present? && activity[:last_activity_at].present?

      {
        actor: activity[:worker].nickname, label: activity[:latest_progress],
        at: activity[:last_activity_at], kind: activity[:display_status]
      }
    end
    planner_items = @planner_decisions.map do |decision|
      {
        actor: "Planner", label: planner_activity_label(decision),
        at: decision.completed_at || decision.updated_at || decision.created_at,
        kind: decision.status == "failed" ? "attention" : "planner"
      }
    end

    chaperone_items = @chaperone_reviews.map do |review|
      {
        actor: "Chaperone",
        label: chaperone_activity_label(review),
        at: review.completed_at || review.updated_at || review.created_at,
        kind: review.status == "failed" ? "attention" : "chaperone"
      }
    end

    (event_items.compact + worker_items + planner_items + chaperone_items).sort_by { |item| item[:at] }.reverse.first(12)
  end

  # Routine orchestration phases are already summarized by the Now panel and
  # planner entries. Keep this feed focused on transitions an operator needs
  # to understand or act on.
  def activity_event_visible?(event)
    # A chaperone review already has one canonical activity entry below. Its
    # worker lifecycle is implementation detail, not a second review.
    return false if event["type"].in?(%w[worker.spawned worker.stopped]) && event.dig("payload", "role") == "chaperone"

    # A handoff_rejected event is the worker correcting itself mid-turn (a
    # DiagnosisEvidenceGate citation complaint it then fixed, for example) --
    # only a rejection whose worker never went on to complete a handoff is
    # something an operator needs to see.
    return false if event["type"] == "worker.handoff_rejected" && handoff_later_completed?(event)

    return true unless event["type"] == "run.status"

    event.dig("payload", "phase").in?(%w[blocked_on_user waiting_on_capacity failed stopped completed])
  end

  def handoff_later_completed?(event)
    nickname = event.dig("payload", "nickname")
    return false if nickname.blank?

    @run.workers.where(nickname: nickname).where.not(handoff_completed_at: nil).exists?
  end

  def activity_event_actor(event)
    return "Rails" if event["type"] == "worker.handoff_rejected"
    return event.dig("payload", "nickname").presence || "Worker" if event["type"].start_with?("worker.")

    "Orchestrator"
  end

  def planner_activity_label(decision)
    case decision.status
    when "completed"
      step = decision.decision&.dig("next_step")
      step ? "Chose #{[ step['owner'], step['artifact'] ].compact.join(' → ')}" : "Completed the run"
    when "failed"
      reason = helpers.planner_decision_error_summary(decision)
      "Attempt failed: #{reason}"
    when "awaiting_chaperone"
      "Requested chaperone review"
    when "running"
      "Choosing the next bounded step"
    else
      "Decision queued"
    end
  end

  def attach_chaperone_reviews
    reviews_by_lineage = @chaperone_reviews.index_by(&:lineage_key)
    @worker_activities.each do |activity|
      next unless activity[:worker].role == "chaperone"

      activity[:chaperone_review] = reviews_by_lineage[activity[:assignment_lineage_key]]
    end
  end

  def chaperone_activity_label(review)
    if chaperone_replaced_envelope?(review)
      tier = SpawnRequest.where(run_id: review.run_id, asked_by: "chaperone", requested_role: "planner", lineage_key: review.lineage_key)
        .where("tags LIKE ?", "%stopped_retry%").order(created_at: :desc).pick(:model_tier)
      return "Requested a #{tier || 'small'} planner to replace the failed execution envelope"
    end

    action = {
      "continue_small" => "continued on the small model",
      "promote" => "promoted to the stronger model",
      "stop" => "stopped the lineage"
    }[review.action]

    return "Review failed for #{review.lineage_key}" if review.status == "failed"
    return "Reviewing repeated failures for #{review.lineage_key}" unless action

    "Reviewed #{review.lineage_key} and #{action}"
  end

  def chaperone_replaced_envelope?(review)
    review.action == "stop" && SpawnRequest.where(
      run_id: review.run_id, asked_by: "chaperone", requested_role: "planner", lineage_key: review.lineage_key
    ).where("tags LIKE ?", "%stopped_retry%").exists?
  end

  def collect_artifacts
    artifact_names = (
      SpawnRequest.where(run_id: @run.run_id).pluck(:scope) +
      Array(@latest_tick&.dig("followingSteps")).map { |step| step["artifact"] || step[:artifact] } +
      Orchestrator::ArtifactStore.names(@run.target_root, @run.run_id)
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
