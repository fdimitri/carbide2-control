# operator/object_builders/pvc.rb
module Operator
  module ObjectBuilders
    module Pvc
      module_function

      def build(ctx)
        {
          apiVersion: "v1",
          kind:       "PersistentVolumeClaim",
          metadata: {
            name:            ctx.files_pvc_name,
            namespace:       ctx.workspace_namespace,
            labels:          ctx.common_labels,
            ownerReferences: [ctx.owner_reference]
          },
          spec: {
            accessModes: ["ReadWriteOnce"],
            resources:   { requests: { storage: ctx.storage } },
            storageClassName: ctx.storage_class
          }
        }
      end
    end
  end
end
