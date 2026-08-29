# Authenticated identity for THIS app's users table — the control-plane user.
# user_id here is control's own users.id.
class Api::V1::MeController < ApplicationController
  def show
    render json: { user_id: current_user.id, email: current_user.email }
  end
end
