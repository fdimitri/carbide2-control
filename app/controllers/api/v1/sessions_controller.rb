# ADR-015 renewal: re-sign the login token with a fresh exp while preserving
# auth_time, bounded by the session ceiling. No password re-entry.
class Api::V1::SessionsController < ApplicationController
  def renew
    payload   = current_token_payload
    auth_time = payload&.dig('auth_time')
    return render json: { error: 'token has no auth_time' }, status: :unauthorized unless auth_time

    ceiling = CarbideControl::UserTokenIssuer.ceiling
    if Time.now.to_i - auth_time.to_i > ceiling
      return render json: { error: 'session ceiling reached; sign in again' }, status: :unauthorized
    end

    token = CarbideControl::UserTokenIssuer.issue!(current_user, auth_time: auth_time.to_i)
    render json: { token: token, user: { id: current_user.id, email: current_user.email } }
  end
end
