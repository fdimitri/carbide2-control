# operator/object_builders/deployment.rb
#
# The workspace pod itself: one container running foreman (rails + worker).
# Mirrors charts/workspace/templates/deployment.yaml in carbide2-server
# closely — keep the two in sync, or eventually delete that chart entirely
# once the operator is the only path to a workspace.
#
# When spec.git is set, an init container runs `git clone --depth 1` into the
# files PVC before the main container starts. Idempotent: skips if the
# target dir already has content (handles pod restarts after the initial
# clone).

require "uri"

module Operator
  module ObjectBuilders
    module Deployment
      module_function

      def build(ctx)
        pg = ctx.postgres
        cluster_namespace = pg[:clusterNamespace] || pg["clusterNamespace"] || "carbide-system"
        cluster_name      = pg[:clusterName] || pg["clusterName"] || "carbide-pg"
        creds_secret      = pg[:credentialsSecret] || pg["credentialsSecret"] || "carbide-pg-app"

        replicas = ctx.paused? ? 0 : 1

        {
          apiVersion: "apps/v1",
          kind:       "Deployment",
          metadata: {
            name:            ctx.workspace_name,
            namespace:       ctx.workspace_namespace,
            labels:          ctx.common_labels,
          },
          spec: {
            replicas: replicas,
            strategy: { type: "Recreate" },  # RWO PVC, single replica
            selector: {
              matchLabels: {
                "app.kubernetes.io/instance" => ctx.workspace_name,
                "app.kubernetes.io/name"     => "workspace"
              }
            },
            template: {
              metadata: { labels: ctx.common_labels },
              spec: {
                serviceAccountName: ctx.workspace_name,
                initContainers:     init_containers(ctx),
                containers: [
                  {
                    name:            "workspace",
                    image:           ctx.image,
                    imagePullPolicy: ctx.image_pull_policy,
                    ports: [
                      { name: "rails",  containerPort: 3000 },
                      { name: "worker", containerPort: 8080 }
                    ],
                    env: env_vars(ctx, cluster_namespace, cluster_name, creds_secret),
                    volumeMounts: [
                      { name: "files", mountPath: "/srv/projects" }
                    ],
                    readinessProbe: {
                      httpGet:             { path: "/up", port: "rails" },
                      initialDelaySeconds: 20,
                      periodSeconds:       5,
                      failureThreshold:    12
                    },
                    livenessProbe: {
                      httpGet:             { path: "/up", port: "rails" },
                      initialDelaySeconds: 60,
                      periodSeconds:       30
                    },
                    resources: {
                      requests: { memory: "512Mi", cpu: "200m" },
                      limits:   { memory: "1Gi",   cpu: "1" }
                    }
                  }
                ],
                volumes: [
                  {
                    name: "files",
                    persistentVolumeClaim: { claimName: ctx.files_pvc_name }
                  }
                ]
              }
            }
          }
        }
      end

      def init_containers(ctx)
        containers = []
        if (git = ctx.git)
          url = git[:cloneUrl] || git["cloneUrl"]
          ref = git[:ref]      || git["ref"] || "main"
          if url && !url.empty?
            target = "/srv/projects/#{ctx.project_id}"
            containers << {
              name:  "git-clone",
              image: "alpine/git:latest",
              command: ["/bin/sh", "-c"],
              args: [
                # Idempotent: skip if anything is already there.
                "if [ -z \"$(ls -A #{target} 2>/dev/null)\" ]; then " \
                  "mkdir -p #{target} && " \
                  "git clone --depth 1 -b #{ref} #{url} #{target}; " \
                "else echo '[git-clone] target non-empty, skipping'; fi"
              ],
              volumeMounts: [{ name: "files", mountPath: "/srv/projects" }]
            }
          end
        end
        containers
      end

      def env_vars(ctx, pg_ns, pg_cluster, pg_secret)
        [
          { name: "WORKSPACE_PROJECT_ID", value: ctx.project_id.to_s },
          { name: "WORKSPACE_PROJECT_UUID", value: ctx.project_uuid.to_s },
          { name: "RAILS_ENV",           value: ENV.fetch("WORKSPACE_RAILS_ENV", "development") },
          { name: "PORT",                value: "3000" },
          { name: "WORKER_PORT",         value: "8080" },
          { name: "PROJECTS_ROOT",       value: "/srv/projects" },

          # The Decider: the workspace SPA is NOT baked into the image. The
          # loader (SpaController / ClientRegistry) fetches the pinned build's
          # index.html from the MinIO static tier over in-cluster HTTP; the
          # browser loads the assets via Traefik at /clients/<family>/<sha>/.
          {
            name:  "CARBIDE_CLIENT_TIER_URL",
            value: ENV.fetch("WORKSPACE_CLIENT_TIER_URL",
                             "http://minio.carbide-system.svc.cluster.local:9000/clients")
          },

          # Persistent worker log on the files PVC: survives pod reaping/rollout
          # so an overnight death stays debuggable (kubectl logs vanishes once
          # the pod is gone). Timestamped + heartbeat; see worker/worker.rb.
          { name: "CARBIDE_WORKER_LOG",  value: "/srv/projects/.carbide/worker.log" },

          # Postgres
          { name: "POSTGRES_HOST",       value: "#{pg_cluster}-rw.#{pg_ns}.svc.cluster.local" },
          { name: "POSTGRES_PORT",       value: "5432" },
          { name: "POSTGRES_DB",         value: ctx.database_name },
          {
            name: "POSTGRES_USER",
            valueFrom: { secretKeyRef: { name: pg_secret, key: "username" } }
          },
          {
            name: "POSTGRES_PASSWORD",
            valueFrom: { secretKeyRef: { name: pg_secret, key: "password" } }
          },

          # JWT — control signs RS256 and publishes its public key at the JWKS
          # endpoint; the pod verifies against that (ADR-015). No shared secret
          # is mirrored into the pod.
          {
            name: "CONTROL_JWKS_URL",
            value: ENV.fetch("CONTROL_JWKS_URL",
                             "http://control-plane.carbide-system.svc.cluster.local:3001/.well-known/jwks.json")
          },

          # Host allowlist. Defaults to "*" (accept any Host:) for dev — see
          # workspace_dev_hosts. Set WORKSPACE_DEV_HOSTS to a comma-separated
          # list to tighten per cluster.
          { name: "RAILS_DEV_HOSTS", value: workspace_dev_hosts },

          # Worker shell backend
          { name: "CARBIDE_BACKEND",            value: "kube" },
          { name: "CARBIDE_SHELL_IMAGE",        value: ENV.fetch("WORKSPACE_SHELL_IMAGE", "carbide2-shell:dev") },
          { name: "CARBIDE_SHELL_PULL_POLICY",  value: "IfNotPresent" },
          {
            name: "CARBIDE_NAMESPACE",
            valueFrom: { fieldRef: { fieldPath: "metadata.namespace" } }
          },
          { name: "CARBIDE_PROJECTS_PVC", value: ctx.files_pvc_name }
        ]
      end

      # Comma-separated Rails host allowlist for the workspace pod. Defaults to
      # "*" (accept any Host:) because the previous dev default was a set of
      # RFC-1918 CIDRs, and a hostname Host: header (e.g. dev1.frankd.local) can
      # never match an IP CIDR — so reaching a pod by name produced a 403
      # "Blocked hosts" even though the LAN IP was allowlisted. Set
      # WORKSPACE_DEV_HOSTS to a comma-separated list to tighten; when an
      # explicit list is given the public ingress host parsed from
      # PUBLIC_URL_BASE is appended for convenience.
      def workspace_dev_hosts
        configured = ENV.fetch("WORKSPACE_DEV_HOSTS", "*").strip
        return "*" if configured.empty? || configured == "*"

        hosts = configured.split(",").map(&:strip).reject(&:empty?)
        base  = ENV.fetch("PUBLIC_URL_BASE", "")
        unless base.empty?
          host = begin
            URI.parse(base).host
          rescue URI::InvalidURIError
            nil
          end
          hosts << host if host && !host.empty? && !hosts.include?(host)
        end

        hosts.join(",")
      end
    end
  end
end
