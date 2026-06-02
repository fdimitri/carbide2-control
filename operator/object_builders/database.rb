# operator/object_builders/database.rb
#
# CloudNativePG `Database` Custom Resource — provisions a logical database
# inside the shared CNPG cluster, owned by the cluster's app user. Each
# workspace gets its own DB; they share the cluster.

module Operator
  module ObjectBuilders
    module Database
      module_function

      def build(ctx)
        pg = ctx.postgres
        cluster_namespace = pg[:clusterNamespace] || pg["clusterNamespace"] || "carbide-system"

        {
          apiVersion: "postgresql.cnpg.io/v1",
          kind:       "Database",
          metadata: {
            # CNPG Database CRs live in the same namespace as the Cluster
            # they reference. We name them by project for traceability.
            name:            "carbide-workspace-#{ctx.project_id}",
            namespace:       cluster_namespace,
            labels:          ctx.common_labels
            # No ownerReference: cross-namespace ownerRefs are not allowed.
            # The reconciler explicitly deletes the Database CR during
            # finalizer cleanup.
          },
          spec: {
            name:    ctx.database_name,
            owner:   "app",                          # CNPG default app user
            cluster: { name: pg[:clusterName] || pg["clusterName"] || "carbide-pg" }
          }
        }
      end
    end
  end
end
