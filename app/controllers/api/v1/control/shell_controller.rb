# The shell handle surface (ADR-029 §4). Two callers, two auth schemes, split
# by what each is allowed to learn:
#
#   GET    .../shell          user-authenticated, display only. No pod name,
#                             no exec grant.
#   POST   .../shell          worker-authenticated. The ONLY path that returns
#                             an exec grant, so it never reaches a browser.
#   POST   .../shell/release  worker-authenticated refcount report.
class Api::V1::Control::ShellController < ApplicationController
  skip_before_action :authenticate_request, only: %i[create release]
  before_action :authenticate_worker!, only: %i[create release]

  def show
    project = current_user.control_projects.find(params[:workspace_id])
    render json: ShellStatus.new(project).call.to_h
  end

  # Idempotent, so the worker re-POSTs with backoff instead of needing a
  # separate poll. Minting is gated on ready, which is what keeps an
  # ImagePullBackOff loop from minting a token per attempt.
  def create
    if @project.shell_disabled?
      return render json: { ready: false, phase: 'Disabled', reason: 'shell is disabled for this workspace' },
                    status: :conflict
    end

    # Before the readiness check, not after: on a cold start the pod does not
    # exist yet, and this is the write that brings it up.
    ShellLifecycle.demand!(@project)

    status = ShellStatus.new(@project).call
    unless status.ready
      return render json: { ready: false, phase: status.phase, reason: status.reason }
    end

    grant = CarbideControl::ExecGrant.mint!(@project)
    render json: {
      ready:      true,
      phase:      status.phase,
      namespace:  @project.namespace_name,
      shell_pod:  @project.shell_pod_name,
      exec_token: grant[:token],
      expires_at: grant[:expires_at]
    }
  rescue StandardError => e
    Rails.logger.error("[shell#create] ws-#{@project.id}: #{e.class}: #{e.message}")
    render json: { ready: false, phase: 'Failed', reason: 'could not mint exec grant' },
           status: :service_unavailable
  end

  def release
    ShellLifecycle.report!(@project, terminals: params[:terminals])
    head :no_content
  end

  private

  # The workspace identity comes from the token, not the URL. A worker in ws-7
  # cannot report against ws-9 by asking for it.
  def authenticate_worker!
    token    = request.headers['Authorization'].to_s[/\ABearer\s+(.+)\z/, 1]
    identity = CarbideControl::WorkerAuth.identify(token)
    project_id = identity&.project_id

    return render json: { error: 'unauthorized' }, status: :unauthorized if project_id.nil?

    if project_id != params[:workspace_id].to_i
      return render json: { error: 'workspace mismatch' }, status: :forbidden
    end

    @project = ControlProject.find_by(id: project_id)
    render json: { error: 'workspace not found' }, status: :not_found if @project.nil?
  end
end
