# operator/workspace_reconciler.rb
#
# The reconcile loop. Watches Workspace CRs in CONTROL_NAMESPACE and for each
# event:
#   1. Adds the finalizer if missing.
#   2. If marked-for-deletion: tear down (namespace + CNPG database) then
#      remove the finalizer (which unblocks the actual CR deletion).
#   3. Otherwise: ensure all owned objects exist and match spec.
#   4. Update CR .status (phase, observed generation, conditions).
#
# This is level-triggered: we don't depend on event ordering, every reconcile
# re-derives desired state from CR spec and re-applies. Crash + restart is
# safe.

require "kube_client"
require "builder_context"
require "object_builders/namespace"
require "object_builders/serviceaccount"
require "object_builders/rbac"
require "object_builders/pvc"
require "object_builders/jwt_secret"
require "object_builders/database"
require "object_builders/service"
require "object_builders/ingressroute"
require "object_builders/deployment"

module Operator
  class WorkspaceReconciler
    FINALIZER = "carbide.dev/workspace-cleanup".freeze
    JWT_SOURCE_SECRET = ENV.fetch("JWT_SOURCE_SECRET", "workspace-jwt").freeze
    IMMUTABLE_SPEC_KINDS = %i[persistent_volume_claim].freeze

    def initialize(logger:, namespace:)
      @logger    = logger
      @namespace = namespace
      @stopped   = false
    end

    def stop!
      @stopped = true
    end

    def run!
      until @stopped
        begin
          watch_loop
        rescue StandardError => e
          @logger.error "[reconciler] watch loop crashed: #{e.class}: #{e.message}"
          @logger.error e.backtrace.first(20).join("\n")
          sleep 5
        end
      end
    end

    private

    def watch_loop
      @logger.info "[reconciler] starting watch on workspaces.carbide.dev in #{@namespace}"
      KubeClient.carbide.watch_workspaces(namespace: @namespace) do |event|
        break if @stopped
        handle(event)
      end
    rescue Kubeclient::ResourceNotFoundError => e
      @logger.error "[reconciler] CRD not installed? #{e.message}. Retrying in 30s."
      sleep 30
    end

    def handle(event)
      cr      = event.object.to_h
      ctx     = BuilderContext.new(cr)
      gen     = cr.dig(:metadata, :generation) || cr.dig("metadata", "generation")
      name    = cr.dig(:metadata, :name)       || cr.dig("metadata", "name")
      deleted = cr.dig(:metadata, :deletionTimestamp) || cr.dig("metadata", "deletionTimestamp")

      @logger.info "[reconciler] event=#{event.type} name=#{name} gen=#{gen} deleted=#{!deleted.nil?}"

      if deleted
        teardown!(ctx, cr)
      else
        ensure_finalizer!(cr)
        reconcile!(ctx, cr)
      end
    rescue Kubeclient::HttpError => e
      @logger.error "[reconciler] kube error: HTTP #{e.error_code} #{e.message}"
      update_status(cr, phase: "Failed", message: e.message[0, 500]) rescue nil
    end

    def ensure_finalizer!(cr)
      finalizers = (cr.dig(:metadata, :finalizers) || cr.dig("metadata", "finalizers") || []).dup
      return if finalizers.include?(FINALIZER)

      finalizers << FINALIZER
      patch = { metadata: { finalizers: finalizers } }
      name  = cr.dig(:metadata, :name) || cr.dig("metadata", "name")
      KubeClient.carbide.merge_patch_workspace(name, patch, @namespace)
    end

    def remove_finalizer!(cr)
      finalizers = (cr.dig(:metadata, :finalizers) || cr.dig("metadata", "finalizers") || []).dup
      finalizers.delete(FINALIZER)
      patch = { metadata: { finalizers: finalizers } }
      name  = cr.dig(:metadata, :name) || cr.dig("metadata", "name")
      KubeClient.carbide.merge_patch_workspace(name, patch, @namespace)
    end

    def reconcile!(ctx, cr)
      update_status(cr, phase: "Provisioning", message: "applying objects")

      apply_namespace(ctx)
      apply_namespaced(ctx)
      apply_database(ctx)

      # Status check: is the Deployment Ready?
      ready = deployment_ready?(ctx)
      url   = build_url(ctx)
      if ready
        update_status(cr, phase: "Ready", message: "", url: url)
      else
        update_status(cr, phase: "Provisioning", message: "waiting for pod ready", url: url)
      end
    end

    def teardown!(ctx, cr)
      @logger.info "[reconciler] tearing down #{ctx.workspace_name}"
      update_status(cr, phase: "Terminating", message: "cleaning up resources")

      # Delete the namespace — this cascades all per-ws objects with
      # ownerReferences to the CR.
      begin
        KubeClient.core.delete_namespace(ctx.workspace_namespace)
      rescue Kubeclient::ResourceNotFoundError
        nil
      end

      # Delete the CNPG Database CR (cross-namespace, no ownerRef).
      begin
        cluster_namespace = ctx.postgres[:clusterNamespace] || ctx.postgres["clusterNamespace"] || "carbide-system"
        KubeClient.cnpg.delete_database("carbide-workspace-#{ctx.project_id}", cluster_namespace)
      rescue Kubeclient::ResourceNotFoundError
        nil
      end

      remove_finalizer!(cr)
    end

    # --- apply helpers ---------------------------------------------------

    def apply_namespace(ctx)
      ns_obj = ObjectBuilders::Namespace.build(ctx)
      apply!(KubeClient.core, :namespace, ns_obj)
    end

    def apply_namespaced(ctx)
      sa     = ObjectBuilders::ServiceAccount.build(ctx)
      role   = ObjectBuilders::Rbac.role(ctx)
      rb     = ObjectBuilders::Rbac.role_binding(ctx)
      pvc    = ObjectBuilders::Pvc.build(ctx)
      svc    = ObjectBuilders::Service.build(ctx)
      ir     = ObjectBuilders::IngressRoute.build(ctx)
      mw     = ObjectBuilders::IngressRoute.middleware(ctx)
      dep    = ObjectBuilders::Deployment.build(ctx)
      secret = ObjectBuilders::JwtSecret.build(ctx, data: fetch_jwt_secret_data)

      apply!(KubeClient.core,    :secret,                 secret)
      apply!(KubeClient.core,    :service_account,        sa)
      apply!(KubeClient.rbac,    :role,                   role)
      apply!(KubeClient.rbac,    :role_binding,           rb)
      apply!(KubeClient.core,    :persistent_volume_claim, pvc)
      apply!(KubeClient.core,    :service,                svc)
      apply!(KubeClient.traefik, :middleware,             mw)
      apply!(KubeClient.traefik, :ingress_route,          ir)
      apply!(KubeClient.apps,    :deployment,             dep)
      replicate_pg_credentials(ctx)
    end

    # The workspace Deployment mounts `postgres.credentialsSecret` as env. The
    # source secret lives next to the CNPG Cluster (carbide-system); copy it
    # into the workspace namespace under the same name. Long-term, each
    # workspace gets its own DB role + per-workspace secret.
    def replicate_pg_credentials(ctx)
      pg            = ctx.postgres
      src_namespace = pg[:clusterNamespace] || pg["clusterNamespace"] || "carbide-system"
      secret_name   = pg[:credentialsSecret] || pg["credentialsSecret"]
      return unless secret_name

      src = KubeClient.core.get_secret(secret_name, src_namespace)
      copy = {
        apiVersion: "v1",
        kind:       "Secret",
        metadata: {
          name:      secret_name,
          namespace: ctx.workspace_namespace,
          labels:    ctx.common_labels
        },
        type: src.type,
        data: src.data.to_h
      }
      apply!(KubeClient.core, :secret, copy)
    end

    def apply_database(ctx)
      db = ObjectBuilders::Database.build(ctx)
      apply!(KubeClient.cnpg, :database, db)
    end

    # Generic apply: create if missing, patch if present. K8s server-side
    # apply would be cleaner but kubeclient's support is awkward; this
    # works for our shapes.
    def apply!(client, kind, obj)
      name      = obj.dig(:metadata, :name)
      namespace = obj.dig(:metadata, :namespace)
      getter    = "get_#{kind}"
      creator   = "create_#{kind}"
      updater   = "update_#{kind}"

      begin
        existing = namespace ? client.public_send(getter, name, namespace) : client.public_send(getter, name)
        # Merge our desired metadata.labels + spec onto the existing object.
        # We don't blindly replace because K8s adds server-side fields
        # (resourceVersion, uid, etc.) we mustn't clobber.
        existing.metadata.labels = obj[:metadata][:labels] if obj[:metadata][:labels]
        # PVC spec (and certain other resources) is immutable once bound — only
        # propagate labels for those, never replace the spec.
        unless IMMUTABLE_SPEC_KINDS.include?(kind)
          existing.spec          = obj[:spec]              if obj[:spec]
        end
        existing.data            = obj[:data]              if obj[:data]
        existing.rules           = obj[:rules]             if obj[:rules]
        existing.subjects        = obj[:subjects]          if obj[:subjects]
        existing.roleRef         = obj[:roleRef]           if obj[:roleRef]
        client.public_send(updater, existing)
      rescue Kubeclient::ResourceNotFoundError
        @logger.info "[apply] creating #{kind} #{namespace}/#{name}"
        client.public_send(creator, Kubeclient::Resource.new(obj))
      rescue Kubeclient::HttpError => e
        if e.error_code == 404
          @logger.info "[apply] (HttpError 404) creating #{kind} #{namespace}/#{name}"
          client.public_send(creator, Kubeclient::Resource.new(obj))
        else
          @logger.error "[apply] #{kind} #{namespace}/#{name} failed code=#{e.error_code.inspect}: #{e.message}"
          raise
        end
      end
    end

    # --- status reporting -----------------------------------------------

    def update_status(cr, phase:, message:, url: nil)
      name = cr.dig(:metadata, :name) || cr.dig("metadata", "name")
      gen  = cr.dig(:metadata, :generation) || cr.dig("metadata", "generation")

      status = {
        phase:              phase,
        message:            message.to_s,
        observedGeneration: gen
      }
      status[:url] = url if url
      status[:namespace] = "ws-#{cr.dig(:spec, :projectId) || cr.dig("spec", "projectId")}"

      begin
        KubeClient.carbide.merge_patch_workspace_status(name, { status: status }, @namespace)
      rescue NoMethodError
        # Older kubeclient — fall back to non-subresource patch.
        KubeClient.carbide.merge_patch_workspace(name, { status: status }, @namespace)
      end
    rescue StandardError => e
      @logger.warn "[reconciler] status update failed: #{e.message}"
    end

    def deployment_ready?(ctx)
      dep = KubeClient.apps.get_deployment(ctx.workspace_name, ctx.workspace_namespace)
      desired = dep.spec.replicas.to_i
      ready   = dep.status&.readyReplicas.to_i
      desired > 0 && ready >= desired
    rescue Kubeclient::ResourceNotFoundError
      false
    end

    def build_url(ctx)
      base = ENV.fetch("PUBLIC_URL_BASE", "http://localhost:8080")
      path = ctx.ingress[:pathPrefix] || ctx.ingress["pathPrefix"] || "/w/#{ctx.project_id}"
      "#{base}#{path}/"
    end

    def fetch_jwt_secret_data
      src_ns = ENV.fetch("CONTROL_NAMESPACE", "carbide-system")
      secret = KubeClient.core.get_secret(JWT_SOURCE_SECRET, src_ns)
      secret.data.to_h
    end
  end
end
