# WebAuthn Relying Party configuration (ADR-021).
#
# webauthn-ruby reads origin/rp_id/rp_name from global config, so set them from
# the same PUBLIC_URL_BASE-derived values the rest of control uses. allowed_origins
# must match window.location.origin in the browser during registration/assertion.
WebAuthn.configure do |config|
  config.allowed_origins = [CarbideControl::WebauthnConfig.origin]
  config.rp_name         = CarbideControl::WebauthnConfig.rp_name
  config.rp_id           = CarbideControl::WebauthnConfig.rp_id
end
