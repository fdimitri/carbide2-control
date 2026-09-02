# Authenticated identity for THIS app's users table — the control-plane user.
# user_id here is control's own users.id; uuid is the stable identity.
class Api::V1::MeController < ApplicationController
  def show
    render json: { user_id: current_user.id, email: current_user.email, uuid: current_user.uuid }
  end
end
