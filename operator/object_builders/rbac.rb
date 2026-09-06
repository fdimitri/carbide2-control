# operator/object_builders/rbac.rb
#
# Role + RoleBinding so the workspace pod's worker can manage per-project
# shell Pods within its own namespace. Equivalent to charts/workspace/
# templates/rbac.yaml in carbide2-server.

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
          rules: [
            {
              apiGroups: [""],
              resources: %w[pods pods/exec pods/log pods/portforward],
              verbs:     %w[get list watch create delete deletecollection patch update]
            },
            {
              apiGroups: [""],
              resources: %w[configmaps secrets],
              verbs:     %w[get list watch]
            },
            {
              apiGroups: [""],
              resources: %w[persistentvolumeclaims],
              verbs:     %w[get list watch]
            }
          ]
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
