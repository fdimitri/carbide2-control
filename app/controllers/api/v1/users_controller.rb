# Inspect a control-plane user and their project memberships. Read-only; no
# authz yet (control-side RBAC is deferred).
class Api::V1::UsersController < ApplicationController
  def show
    user = User.find(params[:id])
    render json: {
      id:    user.id,
      email: user.email,
      uuid:  user.uuid,
      memberships: user.project_memberships.map do |m|
        {
          control_project_id: m.control_project_id,
          role: m.role,
          created_at: m.created_at
        }
      end
    }
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'not found' }, status: :not_found
  end
end
