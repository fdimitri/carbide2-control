# operator/object_builders/ingressroute.rb
#
# Traefik IngressRoute that exposes /w/<id>/* and forwards to the workspace
# Service. Mirrors charts/workspace/templates/ingressroute.yaml in
# carbide2-server.

module Operator
  module ObjectBuilders
    module IngressRoute
      module_function

      def build(ctx)
        path_prefix = ctx.ingress[:pathPrefix] || ctx.ingress["pathPrefix"] || "/w/#{ctx.project_id}"
        host        = ctx.ingress[:host]       || ctx.ingress["host"]
        entry_points = ctx.ingress[:entryPoints] || ctx.ingress["entryPoints"] || ["web"]

        match = if host.to_s.empty?
          "PathPrefix(`#{path_prefix}`)"
        else
          "Host(`#{host}`) && PathPrefix(`#{path_prefix}`)"
        end

        {
          apiVersion: "traefik.io/v1alpha1",
          kind:       "IngressRoute",
          metadata: {
            name:            ctx.ingress_route_name,
            namespace:       ctx.workspace_namespace,
            labels:          ctx.common_labels,
            ownerReferences: [ctx.owner_reference]
          },
          spec: {
            entryPoints: entry_points,
            routes: [
              {
                match: match,
                kind:  "Rule",
                services: [
                  { name: ctx.workspace_name, port: 3000 }
                ],
                middlewares: [
                  { name: "#{ctx.workspace_name}-stripprefix" }
                ]
              },
              # Worker WebSocket — Rails proxies it, but for the dev path we
              # expose it directly so the SPA can connect with the JWT it got
              # from the control plane. Same prefix + /ws suffix convention.
              {
                match: "#{match} && PathPrefix(`#{path_prefix}/ws`)",
                kind:  "Rule",
                services: [
                  { name: ctx.workspace_name, port: 8080 }
                ],
                middlewares: [
                  { name: "#{ctx.workspace_name}-stripprefix" }
                ]
              }
            ]
          }
        }
      end

      # Traefik Middleware that strips the /w/<id> prefix before forwarding.
      def middleware(ctx)
        path_prefix = ctx.ingress[:pathPrefix] || ctx.ingress["pathPrefix"] || "/w/#{ctx.project_id}"
        {
          apiVersion: "traefik.io/v1alpha1",
          kind:       "Middleware",
          metadata: {
            name:            "#{ctx.workspace_name}-stripprefix",
            namespace:       ctx.workspace_namespace,
            labels:          ctx.common_labels,
            ownerReferences: [ctx.owner_reference]
          },
          spec: {
            stripPrefix: { prefixes: [path_prefix] }
          }
        }
      end
    end
  end
end
