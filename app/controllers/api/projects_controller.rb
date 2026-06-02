# Dashboard CRUD for projects, plus the per-project JWT minting endpoint
# that the workspace pod will receive on WS connect.
class Api::ProjectsController < ApplicationController
  def index
    projects = current_user.control_projects.order(created_at: :desc)
    render json: projects.map { |p| project_json(p) }
  end

  def show
    render json: project_json(find_project)
  end

  # POST /api/projects {name}
  # Creates the row + writes the Workspace CR + creates owner membership.
  # The operator picks up the CR and provisions the pod asynchronously;
  # the row's status field tracks progress, polled by the dashboard.
  def create
    ActiveRecord::Base.transaction do
      @project = ControlProject.new(name: params[:name], owner: current_user)
      @project.save!
      ProjectMembership.create!(user: current_user, control_project: @project, role: 'owner')
    end

    begin
      CarbideControl::WorkspaceApi.create(@project)
      @project.update!(status: 'provisioning')
    rescue Kubeclient::HttpError => e
      Rails.logger.error("[projects#create] workspace CR write failed: #{e.message}")
      @project.update!(status: 'failed', last_error: e.message[0, 1000])
    end

    render json: project_json(@project), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  def destroy
    project = find_project
    project.update!(status: 'terminating')
    begin
      CarbideControl::WorkspaceApi.delete(project)
    rescue Kubeclient::HttpError => e
      Rails.logger.error("[projects#destroy] workspace CR delete failed: #{e.message}")
    end
    # The DB row stays until the operator confirms namespace teardown via
    # finalizer removal; a background sweeper (TODO) will then destroy it.
    head :no_content
  end

  # POST /api/projects/:id/ws_token
  # Returns the short-lived per-workspace JWT the SPA presents to the
  # workspace pod on WS connect.
  def ws_token
    project = find_project
    token = CarbideControl::JwtIssuer.issue!(user: current_user, project: project)
    render json: { token: token, project_id: project.id, url: workspace_url(project) }
  end

  private

  def find_project
    current_user.control_projects.find(params[:id] || params[:project_id])
  end

  def workspace_url(project)
    base = ENV.fetch('PUBLIC_URL_BASE', 'http://localhost:8080')
    "#{base}#{project.ingress_path_prefix}/"
  end

  def project_json(project)
    # Reflect operator-reported status from the CR when available, falling
    # back to the DB row's status while the CR doesn't exist yet.
    cr = CarbideControl::WorkspaceApi.get(project) rescue nil
    {
      id:           project.id,
      name:         project.name,
      status:       cr&.dig(:status, :phase)&.downcase || project.status,
      url:          cr&.dig(:status, :url) || (project.status == 'ready' ? workspace_url(project) : nil),
      message:      cr&.dig(:status, :message),
      owner_email:  project.owner.email,
      created_at:   project.created_at
    }
  end
end
