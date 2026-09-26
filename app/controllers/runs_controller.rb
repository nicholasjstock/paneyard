require "fileutils"

class RunsController < ApplicationController
  before_action :require_workspace
  before_action :set_run, only: %i[show stop send_message remove_worktree publish close_session retry_publication]

  def index
    @runs = current_workspace.runs.order(created_at: :desc).limit(50).to_a
    @queued = @runs.select { |run| run.status == "queued" }
    @in_flight = @runs.select { |run| run.status.in?(%w[launching running]) }
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
    @pane = @session && Orchestrator::RunSessionRunner.snapshot(@session)
    @checkpoints = @run.checkpoints.to_a
    @artifacts = collect_artifacts
    @timeline = BusEvent.where(run_id: @run.run_id).order(created_at: :desc).limit(12).to_a
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

  # Opening the pull request. A session going idle no longer does this: it
  # reports and waits, and the operator decides here after reading the pane.
  def publish
    unless @run.publishable?
      redirect_to workspace_run_path(current_workspace, @run), alert: "This run has nothing to publish."
      return
    end

    @run.update!(publication_status: "publishing")
    PublishRunJob.perform_later(@run.id)
    redirect_to workspace_run_path(current_workspace, @run), notice: "Opening the pull request…"
  end

  alias_method :retry_publication, :publish

  # Ends a session the operator is finished looking at: kills the CLI, closes
  # the herdr pane, and releases the concurrency slot. Until this is called an
  # idle session keeps both, which is deliberate -- nothing tears a pane down
  # but the operator.
  def close_session
    session = @run.live_session
    if session.nil?
      redirect_to workspace_run_path(current_workspace, @run), alert: "This run has no live session."
      return
    end

    outcome = session.outcome.presence || "failed"
    Orchestrator::RunSessionRunner.finish!(session, outcome:, result: session.result)
    Orchestrator::RunCompletion.call(run: @run, outcome:, summary: session.result)
    redirect_to workspace_run_path(current_workspace, @run), notice: "Closed the session."
  end

  private

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

  # Files the operator attached at launch, copied into the run's artifact
  # store so the session can read them with read_workflow_artifact.
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

  def collect_artifacts
    Orchestrator::ArtifactStore.names(@run.target_root, @run.run_id).map do |name|
      { name:, content: Orchestrator::ArtifactStore.read(@run.target_root, @run.run_id, name) }
    end
  rescue Errno::ENOENT
    []
  end
end
