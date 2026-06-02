# operator/object_builders/jwt_secret.rb
#
# Mirrors the control-plane's `workspace-jwt` Secret into the workspace's
# namespace. The workspace pod reads this as WORKER_JWT_SECRET and uses it
# to verify per-workspace JWTs minted by the control plane.
#
# The reconciler is responsible for reading the source Secret (from
# CONTROL_NAMESPACE) and passing its data dict into this builder.

module Operator
  module ObjectBuilders
    module JwtSecret
      module_function

      # `data` is the base64-encoded value dict from the source Secret.
      def build(ctx, data:)
        {
          apiVersion: "v1",
          kind:       "Secret",
          type:       "Opaque",
          metadata: {
            name:            ctx.jwt_secret_name,
            namespace:       ctx.workspace_namespace,
            labels:          ctx.common_labels,
          },
          data: data
        }
      end
    end
  end
end
