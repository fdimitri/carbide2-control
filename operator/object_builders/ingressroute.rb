# operator/object_builders/ingressroute.rb
#
# Traefik IngressRoute that exposes /w/<id>/* and forwards to the workspace
# Service. Mirrors charts/workspace/templates/ingressroute.yaml in
# carbide2-server.

module Operator
  module ObjectBuilders
    module IngressRoute
      module_function

      # True when HTTPS is forced: websecure is served AND web is also listed,
      # so plain HTTP requests must be redirected up to HTTPS rather than
      # served. A websecure-only or web-only deployment never redirects.
      def force_https?(ctx)
        eps = entry_points(ctx)
        eps.include?("websecure") && eps.include?("web")
      end

      def entry_points(ctx)
        ctx.ingress[:entryPoints] || ctx.ingress["entryPoints"] || %w[web websecure]
      end

      def build(ctx)
        path_prefix = ctx.ingress[:pathPrefix] || ctx.ingress["pathPrefix"] || "/w/#{ctx.project_id}"
        host        = ctx.ingress[:host]       || ctx.ingress["host"]
        # Serve on both the plaintext (web) and TLS (websecure) entrypoints by
        # default. WebRTC's getUserMedia requires a secure context, so the SPA
        # must be reachable over HTTPS; Traefik's built-in self-signed cert
        # covers the dev/LAN case until an operator supplies a real one.
        eps = entry_points(ctx)
        # tls: {} makes Traefik terminate TLS on websecure with its default
        # (self-signed) certificate. A cert resolver / secret can override later.
        tls = ctx.ingress[:tls] || ctx.ingress["tls"]
        tls = {} if tls.nil?

        # A Traefik IngressRoute carrying a `tls` block marks ALL of its routers
        # as TLS routers, so they only match on a TLS entrypoint — serving the
        # same route on the plaintext `web` entrypoint would then 404. When
        # HTTPS is forced we therefore serve the real content on `websecure`
        # ONLY, and hand `web` to a separate redirect IngressRoute (see
        # redirect_route). A non-forced deployment keeps its entrypoints as-is.
        serving_eps = force_https?(ctx) ? %w[websecure] : eps

        match = if host.to_s.empty?
          "PathPrefix(`#{path_prefix}`)"
        else
          "Host(`#{host}`) && PathPrefix(`#{path_prefix}`)"
        end

        spec = {
          entryPoints: serving_eps,
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
        # Only attach TLS when websecure is actually served, so plaintext-only
        # deployments don't get a dangling tls block.
        spec[:tls] = tls if serving_eps.include?("websecure")

        {
          apiVersion: "traefik.io/v1alpha1",
          kind:       "IngressRoute",
          metadata: {
            name:            ctx.ingress_route_name,
            namespace:       ctx.workspace_namespace,
            labels:          ctx.common_labels,
          },
          spec: spec
        }
      end

      # The web-entrypoint IngressRoute that 301-redirects every plain HTTP
      # request up to HTTPS. Returns nil unless HTTPS is forced. The route still
      # names a service (Traefik requires one) but the redirect middleware
      # short-circuits before the backend is ever reached.
      def redirect_route(ctx)
        return nil unless force_https?(ctx)

        path_prefix = ctx.ingress[:pathPrefix] || ctx.ingress["pathPrefix"] || "/w/#{ctx.project_id}"
        host        = ctx.ingress[:host]       || ctx.ingress["host"]
        match = if host.to_s.empty?
          "PathPrefix(`#{path_prefix}`)"
        else
          "Host(`#{host}`) && PathPrefix(`#{path_prefix}`)"
        end

        {
          apiVersion: "traefik.io/v1alpha1",
          kind:       "IngressRoute",
          metadata: {
            name:            "#{ctx.ingress_route_name}-redirect",
            namespace:       ctx.workspace_namespace,
            labels:          ctx.common_labels,
          },
          spec: {
            entryPoints: %w[web],
            routes: [
              {
                match: match,
                kind:  "Rule",
                services: [
                  { name: ctx.workspace_name, port: 3000 }
                ],
                middlewares: [
                  { name: "#{ctx.workspace_name}-https-redirect" }
                ]
              }
            ]
          }
        }
      end

      # RedirectScheme middleware → https on the public HTTPS port. The explicit
      # port is required because the dev cluster's public HTTPS port (8443)
      # differs from Traefik's internal exposedPort, so a default redirect would
      # send clients to the wrong port. Returns nil unless HTTPS is forced.
      def redirect_middleware(ctx)
        return nil unless force_https?(ctx)

        https_port = (ctx.ingress[:publicHttpsPort] || ctx.ingress["publicHttpsPort"] || 8443).to_s
        {
          apiVersion: "traefik.io/v1alpha1",
          kind:       "Middleware",
          metadata: {
            name:            "#{ctx.workspace_name}-https-redirect",
            namespace:       ctx.workspace_namespace,
            labels:          ctx.common_labels,
          },
          spec: {
            redirectScheme: {
              scheme:    "https",
              port:      https_port,
              permanent: true
            }
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
          },
          spec: {
            stripPrefix: { prefixes: [path_prefix] }
          }
        }
      end
    end
  end
end
