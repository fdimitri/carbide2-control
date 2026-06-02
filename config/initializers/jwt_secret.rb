# Shared secret used to sign per-workspace JWTs. Must match the value the
# operator mirrors into every ws-N namespace (workspace pod reads it as
# WORKER_JWT_SECRET).
#
# In dev, set CARBIDE_JWT_SECRET in .env. In k8s, it's mounted from the
# `workspace-jwt` Secret in the control-plane namespace.

CARBIDE_JWT_SECRET = ENV.fetch('CARBIDE_JWT_SECRET') do
  if Rails.env.production?
    raise 'CARBIDE_JWT_SECRET must be set in production'
  else
    Rails.logger.warn('[carbide-control] CARBIDE_JWT_SECRET unset; using dev fallback')
    'dev-fallback-secret-do-not-use-in-prod'
  end
end.freeze
