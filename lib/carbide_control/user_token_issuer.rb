# frozen_string_literal: true

require 'jwt'

module CarbideControl
  # Mints the control LOGIN token (the dashboard bearer, distinct from the
  # workspace token in JwtIssuer). RS256, same signing key.
  #
  # ADR-015 renewal: the token carries `auth_time` (fixed at first login,
  # preserved through renew). Renew re-signs with a fresh exp; it is rejected
  # once now - auth_time exceeds the session ceiling (a control-side Setting).
  module UserTokenIssuer
    ISSUER        = 'carbide-control'.freeze
    AUDIENCE      = 'control:dashboard'.freeze
    SCOPE         = 'control:user'.freeze
    TTL           = 24 * 60 * 60  # login token lifetime

    CEILING_KEY    = 'session_ceiling'.freeze
    CEILING_DEFAULT = 7 * 24 * 60 * 60  # 7 days

    module_function

    def issue!(user, auth_time: nil)
      now = Time.now.to_i
      payload = {
        iss:        ISSUER,
        sub:        "user:#{user.id}",
        aud:        AUDIENCE,
        iat:        now,
        exp:        now + TTL,
        user_id:    user.id,
        user_uuid:  user.uuid,
        scope:      SCOPE,
        auth_time:  auth_time || now
      }
      JWT.encode(payload, CarbideControl::JwtSigningKey.private_key, 'RS256', { kid: CarbideControl::JwtSigningKey.kid })
    end

    # The absolute session ceiling in seconds (configurable control-side
    # setting, env bootstrap-only).
    def ceiling
      Setting.get(CEILING_KEY, default: CEILING_DEFAULT, env: 'SESSION_CEILING')
    end
  end
end
