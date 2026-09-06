# Dashboard CRUD for Workspaces (top-level control-plane resource), plus the
# per-workspace JWT minting endpoint that the workspace pod will receive on
# WS connect. Backed by the ControlProject model (legacy table name).
class Api::V1::Control::WorkspacesController < ApplicationController
  def index
    workspaces = current_user.control_projects.order(created_at: :desc)
    render json: workspaces.map { |w| workspace_json(w) }
  end

  def show
    render json: workspace_json(find_workspace)
  end

  # POST /api/v1/control/workspaces {name, description?}
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
    # The operator owns async teardown of the pod/namespace/PVC via the CR's
    # ownerReferences once the CR is gone. The control-plane row itself has no
    # reason to linger — delete it so the dashboard doesn't show ghost
    # "terminating" entries forever. Memberships cascade via dependent: :destroy.
    workspace.destroy
    head :no_content
  end

  # POST /api/v1/control/workspaces/:id/token
  # Returns a short-lived per-workspace JWT for the requested scope. The SPA
  # presents a workspace:rw token to the worker and a workspace:api token to the
  # workspace REST API. Scope selects the TTL (see CarbideControl::JwtIssuer).
  def token
    workspace = find_workspace
    scope = CarbideControl::JwtIssuer::SCOPES.include?(params[:scope]) ? params[:scope] : 'workspace:rw'
    token = CarbideControl::JwtIssuer.issue!(user: current_user, project: workspace, scope: scope)
    render json: {
      token: token,
      workspace_id: workspace.id,
      workspace_uuid: workspace.uuid,
      url: workspace_url(workspace),
      scope: scope,
      user: { id: current_user.id, email: current_user.email }
    }
  end

  # PATCH /api/v1/control/workspaces/:id — patchable CR spec fields only.
  # template_name is DB-authoritative: it updates ControlProject.template_name
  # AND writes the resolved resources into the CR spec. Storage fields rejected.
  def update
    workspace = find_workspace

    # Reject non-patchable fields BEFORE mutating anything, so a 422 can't
    # leave the DB changed while the CR stays untouched (#4).
    forbidden = %w[storageSize storageClassName]
    if (params.keys.map(&:to_s) & forbidden).any?
      return render json: { error: 'storage fields are not patchable (ADR-016)' }, status: :unprocessable_entity
    end

    patch    = {}

    if params[:template_name].present?
      template = WorkspaceTemplate.find_by!(name: params[:template_name])
      workspace.update!(template_name: template.name)
      patch[:resources] = template.resources
    end

    if params[:resources].present?
      patch[:resources] = params[:resources].to_unsafe_h.slice(:requests, :limits)
      # Raw resources is an explicit override: it ALWAYS clears the template
      # assignment, even when template_name is also present. Sending both means
      # "go custom with these values," not "track the template but pretend."
      # This keeps control's own writes from ever producing the both-sent
      # ambiguity where template_name disagrees with spec.resources.
      workspace.update!(template_name: nil)
    end

    if params[:workspaceImageTag].present?
      patch[:workspaceImageTag] = params[:workspaceImageTag]
      # Store the intended tag on the control row so spec_drift? has a second
      # side to compare against (the CR is writable out-of-band).
      workspace.update!(workspace_image_tag: params[:workspaceImageTag])
    end

    return render json: { error: 'no patchable fields provided' }, status: :unprocessable_entity if patch.empty?

    CarbideControl::WorkspaceApi.merge_patch(workspace, spec: patch) unless patch.empty?
    render json: workspace_json(workspace)
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'template not found' }, status: :not_found
  end

  # POST /api/v1/control/workspaces/:id/roll — bump rollRequestedAt so the
  # operator restarts the Deployment. Patch-only by default; this is the
  # explicit, disruptive action.
  def roll
    workspace = find_workspace
    CarbideControl::WorkspaceApi.merge_patch(workspace, spec: { rollRequestedAt: Time.now.utc.iso8601 })
    render json: { ok: true }
  end

  # PATCH /api/v1/control/workspaces/:id/shell_mode {mode}
  # Separate from #update because a mode flip is not a plain column write:
  # eager -> lazy has to arm the idle latch (ADR-029 §2), so it goes through
  # ShellLifecycle rather than assigning the attribute here.
  def shell_mode
    workspace = find_workspace
    mode = params[:mode].to_s

    unless ControlProject::SHELL_MODES.include?(mode)
      return render json: { error: "mode must be one of: #{ControlProject::SHELL_MODES.join(', ')}" },
                    status: :unprocessable_entity
    end

    ShellLifecycle.set_mode!(workspace, mode)
    CarbideControl::WorkspaceApi.merge_patch(
      workspace, spec: { shell: { mode: workspace.shell_mode, replicas: workspace.shell_replicas.to_i } }
    )
    render json: { mode: workspace.shell_mode, replicas: workspace.shell_replicas }
  end

  # GET /api/v1/control/workspace-templates — the seeded resource presets.
  def templates
    render json: WorkspaceTemplate.order(:name).map { |t|
      { name: t.name, resources: t.resources, storage_size: t.storage_size, is_default: t.is_default }
    }
  end

  # GET /api/v1/control/workspaces/:id/health
  # Active reachability probe for the workspace pod: is the container up (CR
  # phase), does Rails answer, and does the worker WebSocket upgrade. Kept
  # separate from #index so the list stays fast; the dashboard polls this
  # per-card.
  def health
    workspace = find_workspace
    cr    = CarbideControl::WorkspaceApi.get(workspace) rescue nil
    phase = cr&.dig(:status, :phase)&.downcase || workspace.status
    probe = WorkspaceHealthProbe.new(workspace).call
    render json: {
      id:        workspace.id,
      phase:     phase,
      reachable: { rails: probe[:rails], ws: probe[:ws] },
      ok:        probe[:ok]
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
    spec = cr&.dig(:spec) || {}
    resources = spec[:resources] || spec["resources"]
    {
      id:           workspace.id,
      uuid:         workspace.uuid,
      name:         workspace.name,
      status:       cr&.dig(:status, :phase)&.downcase || workspace.status,
      url:          cr&.dig(:status, :url) || (workspace.status == 'ready' ? workspace_url(workspace) : nil),
      message:      cr&.dig(:status, :message),
      owner_email:  workspace.owner.email,
      created_at:   workspace.created_at,
      resources:    resources,
      template_name: workspace.template_name,
      shell_mode:   workspace.shell_mode,
      spec_drift:       spec_drift?(workspace, spec),
      resources_drift:  resources_drift?(workspace, spec),
      image_tag_drift:  image_tag_drift?(workspace, spec)
    }
  end

  # Composite drift: true when ANY intended value disagrees with the live CR.
  # Coarse "it drifted" signal the UI can show before the per-field breakdown.
  def spec_drift?(workspace, spec)
    resources_drift?(workspace, spec) || image_tag_drift?(workspace, spec)
  end

  # Resources drift: the CR's applied resources differ from the assigned
  # template's CURRENT definition (template edited since assignment, or an
  # out-of-band resources write). A nil template (custom) is never drift.
  def resources_drift?(workspace, spec)
    template  = workspace.template
    resources = spec[:resources] || spec["resources"]
    return false if template.nil? || resources.nil?

    deep_symbolize(resources) != template.resources
  end

  # Image-tag drift: the CR's workspaceImageTag differs from the intended tag
  # stored on the control row (set on the last control PATCH). An out-of-band
  # tag write shows up here.
  def image_tag_drift?(workspace, spec)
    intended = workspace.workspace_image_tag
    actual   = spec[:workspaceImageTag] || spec["workspaceImageTag"]
    return false if intended.nil? || actual.nil?

    actual.to_s != intended.to_s
  end

  def deep_symbolize(obj)
    case obj
    when Hash then obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize(v) }
    when Array then obj.map { |v| deep_symbolize(v) }
    else
      obj.respond_to?(:to_h) ? deep_symbolize(obj.to_h) : obj
    end
  end
end
