# Mints per-workspace JWTs for a requested scope. Verified by carbide2-server's
# Api::BaseController (workspace:api) and the worker (workspace:rw). The wire
# format is documented in JWT_CLAIMS.md — keep both repos in sync by hand.
#
# A JWT is minted for ONE purpose: the requested scope selects its TTL. Both
# scopes currently share the same short TTL; the value is a single env override
# until it moves to proper config.
#
# Usage:
#   token = CarbideControl::JwtIssuer.issue!(user:, project:, scope: 'workspace:rw')

module CarbideControl
  module JwtIssuer
    ISSUER = 'carbide-control'.freeze

    # TTL is a durable control-side setting (ADR-015), read at mint time with a
    # short cache; WORKSPACE_TOKEN_TTL env is bootstrap-only.
    TTL_SETTING_KEY = 'workspace_token_ttl'.freeze

    SCOPES     = %w[workspace:rw workspace:api].freeze

    module_function

    def workspace_token_ttl
      Setting.get(TTL_SETTING_KEY, default: 300, env: 'WORKSPACE_TOKEN_TTL')
    end

    def issue!(user:, project:, scope: 'workspace:rw')
      raise ArgumentError, "unknown scope #{scope.inspect}" unless SCOPES.include?(scope)
      ttl = workspace_token_ttl
      now = Time.now.to_i
      payload = {
        iss:        ISSUER,
        sub:        "user:#{user.id}",
        aud:        "workspace:#{project.id}",
        iat:        now,
        exp:        now + ttl,
        user_id:    user.id,
        user_email: user.email,
        project_id: project.id,
        scope:      scope,
        # Stable identities (ADR-015). project == workspace under 1:1, so
        # project_uuid and workspace_uuid are the same value today; they
        # diverge when a workspace hosts multiple projects.
        user_uuid:      user.uuid,
        workspace_uuid: project.uuid,
        project_uuid:   project.uuid
      }
      JWT.encode(payload, CarbideControl::JwtSigningKey.private_key, 'RS256', { kid: CarbideControl::JwtSigningKey.kid })
    end
  end
end
