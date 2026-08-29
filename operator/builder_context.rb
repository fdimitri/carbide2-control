# operator/builder_context.rb
#
# Value object passed to every object_builder. Carries the parsed CR plus
# convenience accessors for the names, labels, and ownerReference that every
# resource the operator creates must include.
#
# This lets builder methods stay pure: input = BuilderContext, output =
# Kubeclient::Resource. No network calls, no globals, easy to unit-test.

module Operator
  class BuilderContext
    LABEL_MANAGED_BY = "app.kubernetes.io/managed-by".freeze
    LABEL_PART_OF    = "app.kubernetes.io/part-of".freeze
    LABEL_NAME       = "app.kubernetes.io/name".freeze
    LABEL_INSTANCE   = "app.kubernetes.io/instance".freeze
    LABEL_PROJECT_ID = "carbide.dev/project-id".freeze

    attr_reader :cr, :spec, :metadata

    def initialize(cr)
      @cr       = cr
      @spec     = cr[:spec] || cr["spec"] || {}
      @metadata = cr[:metadata] || cr["metadata"] || {}
    end

    def project_id
      Integer(spec[:projectId] || spec["projectId"])
    end

    def project_uuid
      spec[:projectUuid] || spec["projectUuid"]
    end

    # Derived names. Must match ControlProject#namespace_name etc on the
    # Rails side — these are the source of truth for the operator.
    def workspace_namespace
      "ws-#{project_id}"
    end

    def workspace_name
      "ws-#{project_id}"
    end

    def files_pvc_name
      "ws-#{project_id}-files"
    end

    def ingress_route_name
      "ws-#{project_id}"
    end

    def database_name
      "carbide_workspace_#{project_id}"
    end

    def jwt_secret_name
      "workspace-jwt"
    end

    def ingress
      spec[:ingress] || spec["ingress"] || {}
    end

    def storage
      spec[:storageSize] || spec["storageSize"] || "1Gi"
    end

    def storage_class
      spec[:storageClassName] || spec["storageClassName"] || "local-path"
    end

    def image
      tag = spec[:workspaceImageTag] || spec["workspaceImageTag"] || "dev"
      "#{spec[:workspaceImage] || spec["workspaceImage"]}:#{tag}"
    end

    def image_pull_policy
      spec[:workspaceImagePullPolicy] || spec["workspaceImagePullPolicy"] || "IfNotPresent"
    end

    def postgres
      spec[:postgres] || spec["postgres"] || {}
    end

    def git
      spec[:git] || spec["git"]
    end

    def paused?
      spec[:paused] || spec["paused"] || false
    end

    def common_labels
      {
        LABEL_MANAGED_BY => "carbide2-control",
        LABEL_PART_OF    => "carbide2",
        LABEL_NAME       => "workspace",
        LABEL_INSTANCE   => workspace_name,
        LABEL_PROJECT_ID => project_id.to_s
      }
    end

    # Cross-namespace ownerReferences are NOT supported by Kubernetes garbage
    # collection — the Workspace CR lives in carbide-system while the resources
    # we create live in ws-N, so any ownerRef pointing at the CR triggers
    # OwnerRefInvalidNamespace and the GC deletes our resources immediately.
    # We rely on Namespace deletion (cascading) at teardown instead. This
    # accessor returns nil; builders skip the field when nil.
    def owner_reference
      nil
    end
  end
end
