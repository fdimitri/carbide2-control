# Mints per-workspace JWTs. Verified by carbide2-server's WorkspaceJwt
# verifier. The wire format is documented in JWT_CLAIMS.md — keep both repos
# in sync by hand.
#
# Usage:
#   token = CarbideControl::JwtIssuer.issue!(user:, project:)

module CarbideControl
  module JwtIssuer
    ALGORITHM = 'HS256'.freeze
    ISSUER    = 'carbide-control'.freeze
    TTL       = 5 * 60  # seconds — kept short; tokens are minted on demand.

    module_function

    def issue!(user:, project:)
      now = Time.now.to_i
      payload = {
        iss:        ISSUER,
        sub:        "user:#{user.id}",
        aud:        "workspace:#{project.id}",
        iat:        now,
        exp:        now + TTL,
        user_id:    user.id,
        user_email: user.email,
        project_id: project.id,
        scope:      'workspace:rw'
      }
      JWT.encode(payload, CARBIDE_JWT_SECRET, ALGORITHM)
    end
  end
end
