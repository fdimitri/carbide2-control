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

    # Workspace-pod resources from spec; falls back to the historical defaults
    # for CRs that predate the resources field.
    def resources
      r = spec[:resources] || spec["resources"] || {}
      {
        requests: {
          cpu:    r.dig(:requests, :cpu)    || r.dig("requests", "cpu")    || "200m",
          memory: r.dig(:requests, :memory) || r.dig("requests", "memory") || "512Mi"
        },
        limits: {
          cpu:    r.dig(:limits, :cpu)      || r.dig("limits", "cpu")      || "1",
          memory: r.dig(:limits, :memory)   || r.dig("limits", "memory")   || "1Gi"
        }
      }
    end

    def roll_requested_at
      spec[:rollRequestedAt] || spec["rollRequestedAt"]
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

    # --- shell (ADR-029) ---------------------------------------------------

    def shell
      spec[:shell] || spec["shell"] || {}
    end

    def shell_mode
      shell[:mode] || shell["mode"] || "eager"
    end

    def shell_enabled?
      shell_mode != "disabled"
    end

    # §2 precedence: spec.shell.replicas is consulted ONLY under lazy. Under
    # eager the operator holds 1 whatever the field says, so a refcount-driven
    # 0 can never scale an eager shell down. A paused workspace takes
    # everything to 0 (ADR-016 §4).
    def shell_replicas
      return 0 if paused? || !shell_enabled?
      return 1 unless shell_mode == "lazy"

      value = shell[:replicas] || shell["replicas"]
      value.nil? ? 0 : Integer(value).clamp(0, 1)
    end

    def shell_name
      "ws-#{project_id}-shell"
    end

    def shell_image
      repo = shell[:imageRepo] || shell["imageRepo"] || "carbide2-shell"
      tag  = shell[:imageTag]  || shell["imageTag"]  || "dev"
      "#{repo}:#{tag}"
    end

    def shell_image_pull_policy
      shell[:imagePullPolicy] || shell["imagePullPolicy"] || "IfNotPresent"
    end

    # Falls back to what project_pod.rb hardcoded, so a CR written before the
    # template gained shell columns still gets the shape it had.
    def shell_resources
      r = shell[:resources] || shell["resources"] || {}
      {
        requests: {
          cpu:    r.dig(:requests, :cpu)    || r.dig("requests", "cpu")    || "50m",
          memory: r.dig(:requests, :memory) || r.dig("requests", "memory") || "128Mi"
        },
        limits: {
          cpu:    r.dig(:limits, :cpu)      || r.dig("limits", "cpu")      || "6",
          memory: r.dig(:limits, :memory)   || r.dig("limits", "memory")   || "8Gi"
        }
      }
    end

    def shell_labels
      common_labels.merge(
        LABEL_NAME     => "carbide2-shell",
        LABEL_INSTANCE => shell_name
      )
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
