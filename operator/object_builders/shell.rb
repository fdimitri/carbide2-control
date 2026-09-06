# operator/object_builders/shell.rb
#
# The shell pod (ADR-029). Replaces carbide2-worker's ProjectPod, which created
# a bare Pod by shelling out to kubectl from inside the workspace.
#
# A StatefulSet rather than a Deployment purely for the pod name: ordinal
# naming makes `ws-N-shell-0` derivable, so Rails can resolve the exec target
# without anything having to publish and refresh a pod name that eviction, OOM
# kill, or drain would invalidate between reconciles.
#
# volumeClaimTemplates is deliberately unused — the shell mounts the workspace's
# existing PVC, so the usual StatefulSet trap of orphaned per-replica PVCs does
# not apply here.

module Operator
  module ObjectBuilders
    module Shell
      MOUNT_PATH = "/workspace".freeze

      module_function

      def build(ctx)
        {
          apiVersion: "apps/v1",
          kind:       "StatefulSet",
          metadata: {
            name:      ctx.shell_name,
            namespace: ctx.workspace_namespace,
            labels:    ctx.shell_labels
          },
          spec: {
            replicas:    ctx.shell_replicas,
            serviceName: ctx.shell_name,
            # At replicas 1 a StatefulSet does not surge, so an image roll is
            # terminate-then-create: a window with no shell, never two shells
            # fighting over the same RWO volume.
            podManagementPolicy: "OrderedReady",
            updateStrategy: { type: "RollingUpdate" },
            selector: {
              matchLabels: {
                "app.kubernetes.io/instance" => ctx.shell_name,
                "app.kubernetes.io/name"     => "carbide2-shell"
              }
            },
            template: {
              metadata: { labels: ctx.shell_labels },
              spec: pod_spec(ctx)
            }
          }
        }
      end

      # spec.serviceName is required by the API. Nothing resolves the shell by
      # DNS — exec addresses the pod directly — so this exists only to satisfy
      # validation.
      def service(ctx)
        {
          apiVersion: "v1",
          kind:       "Service",
          metadata: {
            name:      ctx.shell_name,
            namespace: ctx.workspace_namespace,
            labels:    ctx.shell_labels
          },
          spec: {
            clusterIP: "None",
            selector: {
              "app.kubernetes.io/instance" => ctx.shell_name,
              "app.kubernetes.io/name"     => "carbide2-shell"
            },
            ports: [{ name: "placeholder", port: 1 }]
          }
        }
      end

      def pod_spec(ctx)
        mounts = [{ name: "files", mountPath: MOUNT_PATH, subPath: ctx.project_id.to_s }]

        {
          terminationGracePeriodSeconds: 5,
          # Runs as the non-root `carbide` user baked into Dockerfile.shell.
          securityContext: { runAsUser: 1000, runAsGroup: 1000, fsGroup: 1000 },
          # kubelet's fsGroup chown does not reliably reach subPath mounts, so
          # local-path's root-owned PV directory would leave /workspace
          # unwritable for uid 1000. Fix it as root before the shell starts.
          initContainers: [{
            name:            "fix-workspace-perms",
            image:           ctx.shell_image,
            imagePullPolicy: ctx.shell_image_pull_policy,
            command:         ["sh", "-c", "chown 1000:1000 #{MOUNT_PATH} && chmod 0775 #{MOUNT_PATH}"],
            securityContext: { runAsUser: 0, runAsGroup: 0 },
            volumeMounts:    mounts
          }],
          containers: [{
            name:            "shell",
            image:           ctx.shell_image,
            imagePullPolicy: ctx.shell_image_pull_policy,
            command:         ["sleep", "infinity"],
            workingDir:      MOUNT_PATH,
            tty:             true,
            stdin:           true,
            resources:       ctx.shell_resources,
            volumeMounts:    mounts
          }],
          volumes: [{
            name: "files",
            persistentVolumeClaim: { claimName: ctx.files_pvc_name }
          }],
          affinity: workspace_node_affinity(ctx)
        }
      end

      # The workspace PVC is ReadWriteOnce, so a shell scheduled onto a
      # different node than the workspace pod fails Multi-Attach and never
      # starts. ProjectPod pinned the node by name, which it could only do
      # because it ran inside the workspace pod; the operator does not know the
      # node, so it expresses the same constraint as pod affinity on the
      # workspace pod's labels. Drops out entirely under ReadWriteMany.
      def workspace_node_affinity(ctx)
        {
          podAffinity: {
            requiredDuringSchedulingIgnoredDuringExecution: [{
              topologyKey: "kubernetes.io/hostname",
              labelSelector: {
                matchLabels: {
                  "app.kubernetes.io/instance" => ctx.workspace_name,
                  "app.kubernetes.io/name"     => "workspace"
                }
              }
            }]
          }
        }
      end
    end
  end
end
