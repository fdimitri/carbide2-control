# operator/object_builders/rbac.rb
#
# Per-workspace RBAC.
#
# ADR-029 emptied the workspace pod's own Role. It used to hold pods, pods/exec,
# pods/log, pods/portforward, configmaps, secrets and persistentvolumeclaims,
# because the worker created and deleted its own shell pods. It does not any
# more -- the shell is an operator-owned StatefulSet, and exec happens with a
# short-lived token minted per request. Standing exec on your own namespace is
# exactly the thing that made a worker compromise interesting, so the Role is
# now empty rather than trimmed: nothing in the worker reads a configmap, a
# secret or a PVC through the API, so leaving those in would be granting
# permissions for a caller that no longer exists.
#
# The Role and RoleBinding are still created, deliberately. Deleting them would
# leave the previous, wide Role in place on every already-reconciled workspace,
# since the operator only applies -- it does not garbage-collect objects it has
# stopped building. Applying an empty ruleset is what actually revokes them.

module Operator
  module ObjectBuilders
    module Rbac
      module_function

      def role(ctx)
        {
          apiVersion: "rbac.authorization.k8s.io/v1",
          kind:       "Role",
          metadata: {
            name:            ctx.workspace_name,
            namespace:       ctx.workspace_namespace,
            labels:          ctx.common_labels,
          },
          rules: []
        }
      end

      def role_binding(ctx)
        {
          apiVersion: "rbac.authorization.k8s.io/v1",
          kind:       "RoleBinding",
          metadata: {
            name:            ctx.workspace_name,
            namespace:       ctx.workspace_namespace,
            labels:          ctx.common_labels,
          },
          subjects: [{
            kind:      "ServiceAccount",
            name:      ctx.workspace_name,
            namespace: ctx.workspace_namespace
          }],
          roleRef: {
            apiGroup: "rbac.authorization.k8s.io",
            kind:     "Role",
            name:     ctx.workspace_name
          }
        }
      end

      # --- shell exec grant (ADR-029 §6) -------------------------------------
      #
      # The operator creates the SUBJECTS and the BINDINGS; the two ClusterRoles
      # they point at are installed once by the chart. No Role is ever created
      # here, which is what keeps this out of privilege-escalation territory.
      #
      # No ownerReference: the CR lives in carbide-system and these live in
      # ws-N, and a cross-namespace ownerRef makes the GC treat the owner as
      # missing and collect them immediately. Namespace teardown is the
      # ownership mechanism.

      def exec_service_account(ctx)
        {
          apiVersion: "v1",
          kind:       "ServiceAccount",
          metadata: {
            name:      ctx.exec_service_account_name,
            namespace: ctx.workspace_namespace,
            labels:    ctx.common_labels
          }
        }
      end

      # Grants the exec SA `get pods` + `create pods/exec`, in this namespace
      # only. Rails mints short-lived tokens against this SA, so the token
      # inherits exactly this and nothing else.
      def exec_role_binding(ctx)
        {
          apiVersion: "rbac.authorization.k8s.io/v1",
          kind:       "RoleBinding",
          metadata: {
            name:      "#{ctx.workspace_name}-exec",
            namespace: ctx.workspace_namespace,
            labels:    ctx.common_labels
          },
          subjects: [{
            kind:      "ServiceAccount",
            name:      ctx.exec_service_account_name,
            namespace: ctx.workspace_namespace
          }],
          roleRef: {
            apiGroup: "rbac.authorization.k8s.io",
            kind:     "ClusterRole",
            name:     "carbide-workspace-exec"
          }
        }
      end

      # Lets the Rails SA mint tokens for ServiceAccounts in THIS namespace.
      # Scoped per-workspace rather than cluster-wide so Rails cannot mint for
      # an arbitrary SA anywhere.
      def token_mint_role_binding(ctx)
        {
          apiVersion: "rbac.authorization.k8s.io/v1",
          kind:       "RoleBinding",
          metadata: {
            name:      "#{ctx.workspace_name}-token-mint",
            namespace: ctx.workspace_namespace,
            labels:    ctx.common_labels
          },
          subjects: [{
            kind:      "ServiceAccount",
            name:      ctx.rails_service_account_name,
            namespace: ctx.control_namespace
          }],
          roleRef: {
            apiGroup: "rbac.authorization.k8s.io",
            kind:     "ClusterRole",
            name:     "carbide-workspace-token-mint"
          }
        }
      end
    end
  end
end
