# Passkey assertion at the login screen (ADR-021). Unauthenticated by design:
# this is how a user proves identity BEFORE we mint the login token.
#
# Non-resident keys require the username first (the server must return the
# credential IDs for the browser to offer), so the flow is username-first.
require 'base64'

class Api::V1::WebauthnLoginController < ActionController::API
  # POST /api/v1/webauthn/assertion/begin { email }
  def assertion_begin
    email = params[:email].to_s.downcase.strip
    return render json: { error: 'email is required' }, status: :bad_request if email.empty?

    user = User.find_by(email: email)
    return render json: { error: 'no passkeys for this account' }, status: :not_found if user.nil? || user.webauthn_credentials.none?

    options = WebAuthn::Credential.options_for_get(
      allow: user.webauthn_credentials.map(&:external_id)
    )

    WebauthnChallenge.issue!(challenge: options.challenge)

    render json: { challenge: options.challenge, options: options.as_json }
  end

  # POST /api/v1/webauthn/assertion/complete { email, challenge, credential }
  def assertion_complete
    email = params[:email].to_s.downcase.strip
    user  = User.find_by(email: email)
    return render json: { error: 'invalid credentials' }, status: :unauthorized if user.nil?

    stored = WebauthnChallenge.unexpired.find_by(challenge: params[:challenge])
    return render json: { error: 'challenge not found or expired' }, status: :bad_request unless stored

    begin
      credential = WebAuthn::Credential.from_get(params[:credential])
      stored_credential = user.webauthn_credentials.find_by!(external_id: credential.id)
      credential.verify(
        stored.challenge,
        public_key: stored_credential.public_key,
        sign_count: stored_credential.sign_count
      )
    rescue WebAuthn::Error, ActiveRecord::RecordNotFound => e
      return render json: { error: "verification failed: #{e.message}" }, status: :unprocessable_entity
    end

    stored_credential.update!(sign_count: credential.sign_count)
    stored.consume!

    token = CarbideControl::UserTokenIssuer.issue!(user)
    render json: { token: token, user: { id: user.id, email: user.email } }
  end
end
