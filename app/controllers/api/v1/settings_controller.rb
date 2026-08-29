# Control-side settings (ADR-015). Global key-value policy store; read + edit.
# No authz yet (any authenticated control user can read/write; RBAC deferred).
class Api::V1::SettingsController < ApplicationController
  def index
    render json: Setting.order(:key).map { |s| { key: s.key, value: s.value } }
  end

  def update
    key   = params[:id].to_s
    value = params[:value].to_s
    return render json: { error: 'value is required' }, status: :unprocessable_entity if value.empty?

    render json: { key: key, value: Setting.set(key, value) }
  end
end
