class WorkspacesController < ApplicationController
  def index
    @workspaces = Workspace.order(:name)
  end

  def new
    @workspace = Workspace.new
  end

  def create
    @workspace = Workspace.new(workspace_params)

    if @workspace.save
      redirect_to workspaces_path, notice: "Added workspace #{@workspace.name}."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    workspace = Workspace.find(params[:id])
    workspace.destroy
    redirect_to workspaces_path, notice: "Removed workspace #{workspace.name}."
  end

  private

  def workspace_params
    params.require(:workspace).permit(:name, :root_path)
  end
end
