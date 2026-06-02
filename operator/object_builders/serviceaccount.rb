# operator/object_builders/serviceaccount.rb
#
# The workspace pod itself runs as this SA. With the `kube` backend
# (worker.backend in the chart), the worker exec's into per-project shell
# Pods using this SA's token, so it needs Pod create/exec/log/delete RBAC
# within its own namespace. The corresponding Role + RoleBinding are built
# by rbac.rb.

module Operator
  module ObjectBuilders
    module ServiceAccount
      module_function

      def build(ctx)
        {
          apiVersion: "v1",
          kind:       "ServiceAccount",
          metadata: {
            name:            ctx.workspace_name,
            namespace:       ctx.workspace_namespace,
            labels:          ctx.common_labels,
          }
        }
      end
    end
  end
end
