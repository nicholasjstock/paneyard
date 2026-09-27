require "fileutils"

class RunsController < ApplicationController
  before_action :require_workspace
  before_action :set_run, only: %i[show stop send_message remove_worktree close_session]

  def index
    @runs = current_workspace.runs.order(created_at: :desc).limit(50).to_a
    @queued = @runs.select { |run| run.status == "queued" }
    @in_flight = @runs.select { |run| run.status.in?(%w[launching running]) }
    @kept_worktrees = @runs.select(&:kept_worktree?)
    @concurrency_limit = Orchestrator::RunConcurrency.limit
  end

  def new
    @run = current_workspace.runs.new(launcher_variant: "claude")
  end

  # Creating a run only queues it. RunDispatchJob starts it when a slot is
  # free -- there is no per-run launcher process and nothing to supervise.
  def create
    @run = current_workspace.runs.new(run_params)
    @run.run_id = generate_run_id
    @run.worktree_name = Orchestrator::GitWorktree.name_for(@run)
    @run.status = "queued"
    @run.launched_by = current_operator
    @run.target_root = current_workspace.source_root
    @run.model = @run.model.presence
    validate_model_choice(@run)
    @run.launch_artifacts = uploaded_artifacts(launch_files_params) if @run.errors.empty?

    if @run.errors.empty? && @run.save
      RunDispatchJob.perform_later
      redirect_to workspace_run_path(current_workspace, @run), notice: "Queued #{@run.run_id}…"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @session = @run.latest_session
    @checkpoints = @run.checkpoints.to_a
    @artifacts = collect_artifacts
  end

  def stop
    StopRunJob.perform_now(@run.id)
    redirect_to workspace_run_path(current_workspace, @run), notice: "Stopped #{@run.run_id}."
  end

  # The operator's steering wheel: type into the live session from the run
  # screen instead of switching to their herdr client. This replaced the whole
  # blocking-question protocol -- there is always a live session to say it to.
  def send_message
    session = @run.live_session
    if session.nil?
      redirect_to workspace_run_path(current_workspace, @run), alert: "This run has no live session."
      return
    end

    Orchestrator::RunSessionRunner.prompt!(session, params.require(:message))
    redirect_to workspace_run_path(current_workspace, @run), notice: "Sent to the session."
  rescue ActionController::ParameterMissing, Orchestrator::RunSessionRunner::Error, Orchestrator::Herdr::Error => error
    redirect_to workspace_run_path(current_workspace, @run), alert: error.message
  end

  def remove_worktree
    Orchestrator::WorktreeJanitor.remove_for_run!(@run, force: params[:force].present?)
    redirect_to workspace_run_path(current_workspace, @run), notice: "Removed #{@run.worktree_name}."
  rescue Orchestrator::WorktreeJanitor::Error => error
    redirect_to workspace_run_path(current_workspace, @run), alert: error.message
  end

  # Ends a session the operator is finished looking at: kills the CLI, closes
  # the herdr pane, and releases the concurrency slot. Until this is called an
  # idle session keeps both, which is deliberate -- nothing tears a pane down
  # but the operator. The worktree goes too if its work is already pushed or
  # merged; otherwise it stays for the operator to deal with.
  def close_session
    session = @run.live_session
    if session.nil?
      redirect_to workspace_run_path(current_workspace, @run), alert: "This run has no live session."
      return
    end

    outcome = session.outcome.presence || "failed"
    Orchestrator::RunSessionRunner.finish!(session, outcome:, result: session.result)
    Orchestrator::RunCompletion.call(run: @run, outcome:, summary: session.result)
    redirect_to workspace_run_path(current_workspace, @run), notice: close_session_notice
  end

  private

  def close_session_notice
    if Orchestrator::WorktreeJanitor.release!(@run)
      "Closed the session and removed #{@run.worktree_name}."
    else
      "Closed the session. Kept #{@run.worktree_name}: it has uncommitted or unpushed work."
    end
  rescue Orchestrator::WorktreeJanitor::Error => error
    "Closed the session, but could not remove its worktree: #{error.message}"
  end

  def model_catalog
    @model_catalog ||= Orchestrator::ModelCatalog.all
  end
  helper_method :model_catalog

  def set_run
    @run = current_workspace.runs.find_by!(run_id: params[:id])
  end

  def run_params
    params.require(:run).permit(:task, :launcher_variant, :model)
  end

  # The dropdown only ever offers what the chosen agent's own CLI lists
  # (Orchestrator::ModelCatalog), so anything else -- another agent's model,
  # or one the CLI has since dropped -- is refused here rather than left to
  # fail inside a herdr pane after the run has already taken a slot.
  def validate_model_choice(run)
    return if run.model.blank?
    return if model_catalog.fetch(run.launcher_variant, []).any? { |option| option["id"] == run.model }

    run.errors.add(:model, "#{run.model.inspect} is not a model #{run.launcher_variant} offers")
  end

  def launch_files_params
    params.fetch(:run, {}).permit(launch_files: [])[:launch_files]
  end

  # Files the operator attached at launch. Stored under the workspace's main
  # checkout (target_root is not the worktree yet); RunPrompt gives the
  # session their absolute path and the run screen lists them.
  def uploaded_artifacts(files)
    Array(files).filter_map do |uploaded|
      next unless uploaded.respond_to?(:original_filename) && uploaded.original_filename.present?

      name = File.basename(uploaded.original_filename)
      path = Orchestrator::ArtifactStore.resolve_path(@run.target_root, @run.run_id, name)
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.cp(uploaded.tempfile.path, path)
      { "name" => name, "source_path" => uploaded.original_filename }
    end
  end

  def generate_run_id
    "run-#{Time.current.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(2)}"
  end

  # Launch files live under the main checkout, not the run's worktree (see
  # #uploaded_artifacts), so read them from there once target_root has moved.
  def collect_artifacts
    root = current_workspace.source_root
    Orchestrator::ArtifactStore.names(root, @run.run_id).map do |name|
      { name:, content: Orchestrator::ArtifactStore.read(root, @run.run_id, name) }
    end
  rescue Errno::ENOENT
    []
  end
end
