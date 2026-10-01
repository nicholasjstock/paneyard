class WorkspacesController < ApplicationController
  def index
    @workspaces = Workspace.order(:name)
  end

  def show
    workspace = Workspace.find(params[:id])
    redirect_to workspace_runs_path(workspace)
  end

  def new
    @workspace = Workspace.new
  end

  def create
    @workspace = Workspace.new(workspace_params)
    # The column's own default is a guess; blank asks registration to detect it.
    @workspace.default_base_branch = workspace_params[:default_base_branch].to_s.strip

    if checked_save(@workspace)
      redirect_to workspace_runs_path(@workspace), notice: "Added workspace #{@workspace.name}."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @workspace = Workspace.find(params[:id])
  end

  def update
    @workspace = Workspace.find(params[:id])
    @workspace.assign_attributes(workspace_edit_params)

    if checked_save(@workspace)
      redirect_to workspaces_path, notice: "Updated workspace #{@workspace.name}."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    workspace = Workspace.find(params[:id])

    if workspace.destroy
      redirect_to workspaces_path, notice: "Removed workspace #{workspace.name}."
    else
      redirect_to workspaces_path, alert: workspace.errors.full_messages.to_sentence
    end
  end

  private

  # The same checks register_workspace makes (Orchestrator::WorkspaceRegistration):
  # a new repository, or a changed repository or default branch, must already
  # be usable for runs. An edit that leaves both alone (a layout change) is
  # not held up by it.
  def checked_save(workspace)
    if workspace.new_record? || workspace.will_save_change_to_repository_path? || workspace.will_save_change_to_default_base_branch?
      result = Orchestrator::WorkspaceRegistration.check(
        # Blank (a new workspace's empty field) means detect it.
        path: workspace.repository_path, name: workspace.name, default_base_branch: workspace.default_base_branch.presence,
        workspace:
      )
      workspace.name = result.fetch("name") if workspace.name.blank?
      if result.fetch("problems").empty?
        workspace.repository_path = result.fetch("repository_path")
        workspace.default_base_branch = result.fetch("default_base_branch")
      end
      workspace.valid?
      result.fetch("problems").each do |problem|
        # The model's own presence/uniqueness validations already say these.
        next if problem.fetch("code").in?(%w[name_blank name_taken path_blank])
        next if problem.fetch("code") == "repository_taken" && workspace.errors.added?(:repository_path, :taken)

        workspace.errors.add(:base, problem.fetch("message"))
      end
    else
      workspace.valid?
    end
    workspace.errors.empty? && workspace.save
  end

  def workspace_params
    params.require(:workspace).permit(:name, :repository_path, :default_base_branch, :layout)
  end

  def workspace_edit_params
    params.require(:workspace).permit(:repository_path, :default_base_branch, :layout)
  end
end
