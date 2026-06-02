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
    end
  end
end
