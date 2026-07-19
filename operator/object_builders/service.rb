# operator/object_builders/service.rb
module Operator
  module ObjectBuilders
    module Service
      module_function

      def build(ctx)
        {
          apiVersion: "v1",
          kind:       "Service",
          metadata: {
            name:            ctx.workspace_name,
            namespace:       ctx.workspace_namespace,
            labels:          ctx.common_labels,
          },
          spec: {
            selector: {
              "app.kubernetes.io/instance" => ctx.workspace_name,
              "app.kubernetes.io/name"     => "workspace"
            },
            ports: [
              { name: "rails",  port: 3000, targetPort: "rails" },
              { name: "worker", port: 8080, targetPort: "worker" }
            ]
          }
        }
      end
    end
  end
end
