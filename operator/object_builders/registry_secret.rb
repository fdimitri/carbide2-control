# operator/object_builders/registry_secret.rb
#
# A docker-registry imagePullSecret so the workspace + shell pods can pull from
# an AUTHENTICATED registry (GitLab). A self-hosted registry needs none of this
# (its CA is trusted in the node store), so the builders emit nothing there.
#
# Built only when REGISTRY_USERNAME + REGISTRY_PASSWORD are set. If the operator
# has no credentials it still honors REGISTRY_PULL_SECRET as a reference to a
# secret created out-of-band (the deployment references it, nothing to build).
require "base64"
require "json"

module Operator
  module ObjectBuilders
    module RegistrySecret
      module_function

      def username
        ENV["REGISTRY_USERNAME"].to_s.strip
      end

      def password
        ENV["REGISTRY_PASSWORD"].to_s
      end

      def server
        ENV["REGISTRY_URL"].to_s.sub(%r{\A[a-z]+://}, "").sub(%r{/.*\z}, "")
      end

      # nil when there is nothing to build (no creds, or no secret name given).
      def build(ctx)
        name = ctx.image_pull_secret
        return nil if name.nil? || username.empty? || password.empty?
        return nil if server.empty?

        auth = Base64.strict_encode64("#{username}:#{password}")
        dockerconfig = {
          "auths" => { server => { "username" => username,
                                   "password" => password,
                                   "auth"     => auth } }
        }

        {
          apiVersion: "v1",
          kind:       "Secret",
          metadata: {
            name:      name,
            namespace: ctx.workspace_namespace,
            labels:    ctx.common_labels
          },
          type: "kubernetes.io/dockerconfigjson",
          data: { ".dockerconfigjson" => Base64.strict_encode64(JSON.generate(dockerconfig)) }
        }
      end
    end
  end
end
