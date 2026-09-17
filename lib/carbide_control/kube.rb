# Shared Kubernetes access for the control plane.
#
# ADR-016 §6 invariant 2 says Rails does not mutate cluster state; ADR-029 §4
# and §6 carve out exactly three exceptions, and this module is deliberately
# the only place they live:
#
#   1. GET a Workspace CR by name          (WorkspaceApi, already existed)
#   2. GET one shell pod by a DERIVED name (never a LIST, never a watch)
#   3. POST a TokenReview, and POST a serviceaccounts/token mint
#
# The mint is a subresource write that creates no object, which is why it is a
# named exception rather than a breach. Nothing here enumerates anything: every
# call addresses a single object whose name Rails computed itself.

require 'net/http'

module CarbideControl
  module Kube
    SA_DIR         = '/var/run/secrets/kubernetes.io/serviceaccount'.freeze
    SA_TOKEN_FILE  = "#{SA_DIR}/token".freeze
    SA_CA_FILE     = "#{SA_DIR}/ca.crt".freeze

    module_function

    def in_cluster?
      ENV['KUBERNETES_SERVICE_HOST'].present?
    end

    def api_endpoint
      if in_cluster?
        "https://#{ENV['KUBERNETES_SERVICE_HOST']}:#{ENV['KUBERNETES_SERVICE_PORT']}"
      else
        kube_context.api_endpoint.to_s.sub(%r{/\z}, '')
      end
    end

    # api_path is the group root, e.g. "/api" or "/apis/carbide.dev".
    def client(api_path, version)
      if in_cluster?
        Kubeclient::Client.new(
          "#{api_endpoint}#{api_path}",
          version,
          auth_options: { bearer_token_file: SA_TOKEN_FILE },
          ssl_options:  { ca_file: SA_CA_FILE }
        )
      else
        ctx = kube_context
        Kubeclient::Client.new(
          "#{ctx.api_endpoint}#{api_path}",
          version,
          auth_options: ctx.auth_options,
          ssl_options:  ctx.ssl_options
        )
      end
    end

    def core
      @core ||= client('/api', 'v1')
    end

    def authentication
      @authentication ||= client('/apis/authentication.k8s.io', 'v1')
    end

    def kube_context
      @kube_context ||= Kubeclient::Config
                        .read(ENV.fetch('KUBECONFIG', File.expand_path('~/.kube/config')))
                        .context
    end

    # Subresource POST. Kubeclient generates methods per-resource and has no
    # path for `serviceaccounts/<name>/token`, so this issues the request
    # directly with the same credentials the generated clients use.
    def post_subresource(path, body)
      uri  = URI.parse("#{api_endpoint}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      apply_tls!(http)

      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'application/json'
      request['Accept']       = 'application/json'
      if (token = bearer_token)
        request['Authorization'] = "Bearer #{token}"
      end
      request.body = body.to_json

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        raise "kube POST #{path} returned #{response.code}: #{response.body.to_s[0, 500]}"
      end

      JSON.parse(response.body)
    end

    def apply_tls!(http)
      return unless http.use_ssl?

      if in_cluster?
        http.ca_file = SA_CA_FILE
        return
      end

      ssl = kube_context.ssl_options || {}
      http.ca_file     = ssl[:ca_file] if ssl[:ca_file]
      http.cert        = ssl[:client_cert] if ssl[:client_cert]
      http.key         = ssl[:client_key] if ssl[:client_key]
      http.verify_mode = ssl[:verify_ssl] if ssl.key?(:verify_ssl)
    end

    def bearer_token
      return File.read(SA_TOKEN_FILE).strip if in_cluster?

      (kube_context.auth_options || {})[:bearer_token]
    end
  end
end
