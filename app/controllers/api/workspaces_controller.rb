# Dashboard CRUD for Workspaces (top-level control-plane resource), plus the
# per-workspace JWT minting endpoint that the workspace pod will receive on
# WS connect. Backed by the ControlProject model (legacy table name).
class Api::WorkspacesController < ApplicationController
  def index
    workspaces = current_user.control_projects.order(created_at: :desc)
    render json: workspaces.map { |w| workspace_json(w) }
  end

  def show
    render json: workspace_json(find_workspace)
  end

  # POST /api/workspaces {name, description?}
  # Creates the row + writes the Workspace CR + creates owner membership.
  # The operator picks up the CR and provisions the pod asynchronously;
  # the row's status field tracks progress, polled by the dashboard.
  def create
    ActiveRecord::Base.transaction do
      @workspace = ControlProject.new(name: params[:name], owner: current_user)
      @workspace.save!
      ProjectMembership.create!(user: current_user, control_project: @workspace, role: 'owner')
    end

    begin
      CarbideControl::WorkspaceApi.create(@workspace)
      @workspace.update!(status: 'provisioning')
    rescue Kubeclient::HttpError => e
      Rails.logger.error("[workspaces#create] workspace CR write failed: #{e.message}")
      @workspace.update!(status: 'failed', last_error: e.message[0, 1000])
    end

    render json: workspace_json(@workspace), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def destroy
    workspace = find_workspace
    workspace.update!(status: 'terminating')
    begin
      CarbideControl::WorkspaceApi.delete(workspace)
    rescue Kubeclient::HttpError => e
      Rails.logger.error("[workspaces#destroy] workspace CR delete failed: #{e.message}")
    end
    head :no_content
  end

  # POST /api/workspaces/:id/token
  # Returns the short-lived per-workspace JWT the SPA presents to the
  # workspace pod when bootstrapping its session.
  def token
    workspace = find_workspace
    token = CarbideControl::JwtIssuer.issue!(user: current_user, project: workspace)
    render json: {
      token: token,
      workspace_id: workspace.id,
      url: workspace_url(workspace),
      user: { id: current_user.id, email: current_user.email }
    }
  end

  private

  def find_workspace
    current_user.control_projects.find(params[:id] || params[:workspace_id])
  end

  def workspace_url(workspace)
    base = ENV.fetch('PUBLIC_URL_BASE', 'http://localhost:8080')
    "#{base}#{workspace.ingress_path_prefix}/"
  end

  def workspace_json(workspace)
    cr = CarbideControl::WorkspaceApi.get(workspace) rescue nil
    {
      id:           workspace.id,
      name:         workspace.name,
      status:       cr&.dig(:status, :phase)&.downcase || workspace.status,
      url:          cr&.dig(:status, :url) || (workspace.status == 'ready' ? workspace_url(workspace) : nil),
      message:      cr&.dig(:status, :message),
      owner_email:  workspace.owner.email,
      created_at:   workspace.created_at
    }
  end
end
