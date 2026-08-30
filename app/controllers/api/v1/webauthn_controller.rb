# In-session passkey management (ADR-021): add / list / remove.
#
# Registration is the only ceremony wired in this slice. Assertion (login) is
# deferred to the login-screen work and is intentionally absent here.
class Api::V1::WebauthnController < ApplicationController
  # GET /api/v1/webauthn/credentials
  def index
    render json: current_user.webauthn_credentials.order(:created_at).map { |c|
      { id: c.id, nickname: c.nickname, created_at: c.created_at }
    }
  end

  # POST /api/v1/webauthn/registration/begin
  def registration_begin
    challenge = WebauthnChallenge.issue!(ttl: CarbideControl::WebauthnConfig.challenge_ttl)

    options = webauthn_credential_options.create(
      user: {
        id: webauthn_user_id(current_user),
        name: current_user.email,
        display_name: current_user.email
      },
      challenge: challenge.challenge,
      exclude: current_user.webauthn_credentials.map(&:external_id),
      authenticator_selection: {
        authenticator_attachment: 'cross-platform',
        user_verification: 'preferred',
        resident_key: 'preferred'  # non-resident is acceptable; don't force discoverable
      },
      attestation: 'none'
    )

    render json: { challenge: challenge.challenge, options: options.as_json }
  end

  # POST /api/v1/webauthn/registration/complete
  def registration_complete
    challenge = params[:challenge]
    credential_json = params[:credential]

    stored = WebauthnChallenge.unexpired.find_by(challenge: challenge)
    return render json: { error: 'challenge not found or expired' }, status: :bad_request unless stored

    begin
      credential = WebAuthn::Credential.from_create(credential_json)
      credential.verify(
        stored.challenge,
        rp_id: CarbideControl::WebauthnConfig.rp_id,
        origin: CarbideControl::WebauthnConfig.origin,
        attestation: 'none'
      )
    rescue WebAuthn::Error => e
      return render json: { error: "verification failed: #{e.message}" }, status: :unprocessable_entity
    end

    current_user.webauthn_credentials.create!(
      external_id: credential.id,
      public_key: credential.public_key,
      sign_count: credential.sign_count,
      nickname: params[:nickname].to_s.strip.presence || 'Passkey'
    )
    stored.consume!

    render json: { ok: true }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # DELETE /api/v1/webauthn/credentials/:id
  def destroy
    cred = current_user.webauthn_credentials.find(params[:id])
    cred.destroy!
    head :no_content
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'not found' }, status: :not_found
  end

  private

  def webauthn_credential_options
    WebAuthn::Credential.options_for_create
  end

  def webauthn_user_id(user)
    # A stable, opaque user handle (max 64 bytes). We use the uuid; it's stable
    # and already the cross-DB identity.
    user.uuid.bytes.first(64).pack('C*')
  end
end
