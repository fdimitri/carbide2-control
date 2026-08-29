# Writes / reads / deletes Workspace Custom Resources. The ONLY way Rails
# touches Kubernetes. RBAC for the Rails ServiceAccount allows exactly:
#   create/get/list/watch/delete workspaces.carbide.dev in carbide-system.
#
# The operator is responsible for everything that happens AFTER the CR is
# written. Rails reads `.status` for display but never writes it.

module CarbideControl
  class WorkspaceApi
    GROUP   = 'carbide.dev'.freeze
    VERSION = 'v1'.freeze
    CR_NAMESPACE = ENV.fetch('CONTROL_NAMESPACE', 'carbide-system').freeze

    def self.client
      @client ||= build_client
    end

    def self.build_client
      if ENV['KUBERNETES_SERVICE_HOST']
        # In-cluster: use the mounted ServiceAccount token + CA.
        Kubeclient::Client.new(
          "https://#{ENV['KUBERNETES_SERVICE_HOST']}:#{ENV['KUBERNETES_SERVICE_PORT']}/apis/#{GROUP}",
          VERSION,
          auth_options: { bearer_token_file: '/var/run/secrets/kubernetes.io/serviceaccount/token' },
          ssl_options:  { ca_file: '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt' }
        )
      else
        # Out-of-cluster (dev): read ~/.kube/config.
        config = Kubeclient::Config.read(ENV.fetch('KUBECONFIG', File.expand_path('~/.kube/config')))
        ctx = config.context
        Kubeclient::Client.new(
          "#{ctx.api_endpoint}/apis/#{GROUP}",
          VERSION,
          auth_options: ctx.auth_options,
          ssl_options:  ctx.ssl_options
        )
      end
    end

    # Build the Workspace CR spec from a ControlProject. The operator only
    # ever reads from CR — never from the DB — so everything it needs to
    # provision the workspace must be baked in here.
    def self.cr_for(project)
      {
        apiVersion: "#{GROUP}/#{VERSION}",
        kind:       'Workspace',
        metadata: {
          name:      project.release_name,
          namespace: CR_NAMESPACE,
          labels:    { 'carbide.dev/project-id' => project.id.to_s }
        },
        spec: {
          projectId:       project.id,
          projectUuid:     project.uuid,
          ownerEmail:      project.owner.email,
          workspaceImage:  ENV.fetch('WORKSPACE_IMAGE', 'carbide2'),
          workspaceImageTag: ENV.fetch('WORKSPACE_IMAGE_TAG', 'dev'),
          storageSize:     ENV.fetch('WORKSPACE_STORAGE_SIZE', '1Gi'),
          storageClassName: ENV.fetch('WORKSPACE_STORAGE_CLASS', 'local-path'),
          postgres: {
            clusterName:        ENV.fetch('PG_CLUSTER_NAME', 'carbide-pg'),
            clusterNamespace:   ENV.fetch('PG_CLUSTER_NAMESPACE', 'carbide-system'),
            credentialsSecret:  ENV.fetch('PG_CREDENTIALS_SECRET', 'carbide-pg-app')
          },
          ingress: {
            pathPrefix: project.ingress_path_prefix,
            publicPort: ENV.fetch('INGRESS_PUBLIC_PORT', '8080').to_i,
            # Public HTTPS port the browser uses; the HTTP→HTTPS redirect
            # targets this explicitly because it may differ from Traefik's
            # internal exposedPort (e.g. 8443 in the k3d dev cluster).
            publicHttpsPort: ENV.fetch('INGRESS_PUBLIC_HTTPS_PORT', '8443').to_i,
            # Serve on both the plaintext (web) and TLS (websecure) entrypoints
            # so the workspace is reachable over HTTPS. Override with
            # INGRESS_ENTRYPOINTS (comma-separated) if a deployment only wants
            # one. tls: {} terminates TLS on websecure with Traefik's default
            # cert (self-signed until a real cert is configured).
            entryPoints: ENV.fetch('INGRESS_ENTRYPOINTS', 'web,websecure').split(',').map(&:strip).reject(&:empty?),
            tls: {}
          }
        }
      }
    end

    def self.create(project)
      client.create_workspace(cr_for(project))
    end

    def self.delete(project)
      client.delete_workspace(project.release_name, CR_NAMESPACE)
    rescue Kubeclient::ResourceNotFoundError
      nil
    end

    def self.get(project)
      client.get_workspace(project.release_name, CR_NAMESPACE)
    rescue Kubeclient::ResourceNotFoundError
      nil
    end
  end
end
