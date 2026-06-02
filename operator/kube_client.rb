# operator/kube_client.rb
#
# Thin factory around kubeclient that returns a Kubeclient::Client for any
# (group, version) we care about. Handles both in-cluster (mounted SA token)
# and out-of-cluster (~/.kube/config) auth, the same way as
# lib/carbide_control/workspace_api.rb but for arbitrary APIs the operator
# needs to write to.

require "kubeclient"

module Operator
  module KubeClient
    module_function

    # Returns a Kubeclient::Client for a given API endpoint suffix.
    # Examples:
    #   client_for("/api", "v1")                          # core (pods, svc, ns, secrets, pvc, sa)
    #   client_for("/apis/apps", "v1")                    # deployments
    #   client_for("/apis/rbac.authorization.k8s.io", "v1") # roles, rolebindings
    #   client_for("/apis/traefik.io", "v1alpha1")        # ingressroute
    #   client_for("/apis/postgresql.cnpg.io", "v1")      # cnpg databases
    #   client_for("/apis/carbide.dev", "v1")             # workspace CRD
    def client_for(api_path, version)
      cache_key = "#{api_path}|#{version}"
      @cache ||= {}
      @cache[cache_key] ||= build(api_path, version)
    end

    def build(api_path, version)
      if ENV["KUBERNETES_SERVICE_HOST"]
        Kubeclient::Client.new(
          "https://#{ENV['KUBERNETES_SERVICE_HOST']}:#{ENV['KUBERNETES_SERVICE_PORT']}#{api_path}",
          version,
          auth_options: { bearer_token_file: "/var/run/secrets/kubernetes.io/serviceaccount/token" },
          ssl_options:  { ca_file: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt" }
        )
      else
        config = Kubeclient::Config.read(ENV.fetch("KUBECONFIG", File.expand_path("~/.kube/config")))
        ctx = config.context
        Kubeclient::Client.new(
          "#{ctx.api_endpoint}#{api_path}",
          version,
          auth_options: ctx.auth_options,
          ssl_options:  ctx.ssl_options
        )
      end
    end

    # Convenience accessors for the APIs the reconciler uses.
    def core;          client_for("/api", "v1"); end
    def apps;          client_for("/apis/apps", "v1"); end
    def rbac;          client_for("/apis/rbac.authorization.k8s.io", "v1"); end
    def traefik;       client_for("/apis/traefik.io", "v1alpha1"); end
    def cnpg;          client_for("/apis/postgresql.cnpg.io", "v1"); end
    def carbide;       client_for("/apis/carbide.dev", "v1"); end
  end
end
