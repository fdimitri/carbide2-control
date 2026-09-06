# Mints the short-lived, namespace-scoped exec token the worker uses to attach
# a PTY to its shell pod (ADR-029 §6).
#
# This is the one place Rails touches Kubernetes outside the Workspace CR. It
# is a `serviceaccounts/token` subresource POST: it mutates no object, and the
# token it returns is bounded by the target ServiceAccount's own RBAC, which
# the operator has bound to the fixed `carbide-workspace-exec` ClusterRole —
# `get pods` and `create pods/exec`, in that workspace's namespace only.
#
# No boundObjectRef and no resourceNames: a ws-N namespace holds only the
# workspace pod (which the worker already runs inside), its shell, and the
# transient migration job, so namespace scope reaches nothing the worker could
# not already touch. That stops being true the day a per-workspace database pod
# lands in ws-N.
module CarbideControl
  module ExecGrant
    # Long enough to survive a slow attach, short enough that a leaked token is
    # worth little. Namespace teardown is the long-term boundary.
    TTL_SECONDS = Integer(ENV.fetch('SHELL_EXEC_TOKEN_TTL', '600'))

    module_function

    # The dedicated exec ServiceAccount in the workspace's namespace. Separate
    # from the workspace pod's own SA so the grant can be reasoned about (and
    # revoked) on its own.
    def service_account_name(project)
      "#{project.namespace_name}-exec"
    end

    def mint!(project)
      namespace = project.namespace_name
      account   = service_account_name(project)

      result = Kube.post_subresource(
        "/api/v1/namespaces/#{namespace}/serviceaccounts/#{account}/token",
        {
          apiVersion: 'authentication.k8s.io/v1',
          kind:       'TokenRequest',
          spec:       { audiences: ['https://kubernetes.default.svc'], expirationSeconds: TTL_SECONDS }
        }
      )

      {
        token:      result.dig('status', 'token'),
        expires_at: result.dig('status', 'expirationTimestamp')
      }
    end
  end
end
