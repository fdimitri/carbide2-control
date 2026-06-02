# operator/object_builders/namespace.rb
module Operator
  module ObjectBuilders
    module Namespace
      module_function

      # Namespace can't have an ownerReference back to the Workspace CR
      # (CRs are namespaced, Namespaces are cluster-scoped — K8s forbids the
      # reference direction). The reconciler deletes it explicitly on
      # finalizer cleanup.
      def build(ctx)
        {
          apiVersion: "v1",
          kind:       "Namespace",
          metadata: {
            name:   ctx.workspace_namespace,
            labels: ctx.common_labels.merge(
              "carbide.dev/owner-workspace" => ctx.workspace_name
            )
          }
        }
      end
    end
  end
end
