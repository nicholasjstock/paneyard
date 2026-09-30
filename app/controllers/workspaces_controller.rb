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
  # a new root, or a changed one, must already be laid out for runs. An edit
  # that leaves the root alone (a layout change) is not held up by it, so a
  # checkout that is briefly on another branch doesn't block that.
  def checked_save(workspace)
    workspace.valid?
    if workspace.new_record? || workspace.will_save_change_to_root_path?
      result = Orchestrator::WorkspaceRegistration.check(name: workspace.name, root_path: workspace.root_path, workspace:)
      result.fetch("problems").each do |problem|
        # The model's own presence/uniqueness validations already say these.
        next if problem.fetch("code").in?(%w[name_blank name_taken root_path_blank])
        next if problem.fetch("code") == "root_path_taken" && workspace.errors.added?(:root_path, :taken)

        workspace.errors.add(:base, problem.fetch("message"))
      end
      workspace.root_path = result.fetch("root_path") if workspace.errors.empty?
    end
    workspace.errors.empty? && workspace.save
  end

  def workspace_params
    params.require(:workspace).permit(:name, :root_path, :layout)
  end

  def workspace_edit_params
    params.require(:workspace).permit(:root_path, :layout)
  end
end
