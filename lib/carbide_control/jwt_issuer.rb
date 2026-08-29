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
    ALGORITHM   = 'HS256'.freeze
    ISSUER      = 'carbide-control'.freeze
    DEFAULT_TTL = Integer(ENV.fetch('WORKSPACE_TOKEN_TTL', '300'))  # seconds

    SCOPES     = %w[workspace:rw workspace:api].freeze
    SCOPE_TTLS = SCOPES.to_h { |s| [s, DEFAULT_TTL] }.freeze

    module_function

    def issue!(user:, project:, scope: 'workspace:rw')
      raise ArgumentError, "unknown scope #{scope.inspect}" unless SCOPE_TTLS.key?(scope)
      ttl = SCOPE_TTLS.fetch(scope)
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
      JWT.encode(payload, CARBIDE_JWT_SECRET, ALGORITHM)
    end
  end
end
