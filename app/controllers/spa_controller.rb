# Serves the dashboard SPA shell for any non-API, non-asset path so the Vue
# router's history-mode URLs (e.g. /login, /preferences) survive a hard reload.
# The static assets under /assets/* and /clients/* are served by the static
# tier / ActionDispatch::Static before the router; this controller only runs
# for SPA route fallbacks.
#
# The Decider: the dashboard is NOT baked into the control image. It lives only
# in the content-addressed client store (see ClientRegistry) as the
# "carbide2-control" family, served by the MinIO static tier at
# /clients/carbide2-control/<sha>/. This loader resolves a *pinned* build and
# serves that build's index.html. The choice comes from a `?client=` query
# param (which also pins a cookie for subsequent navigations) or the
# `carbide_client` cookie, defaulting to the newest build of the control family.
# The build's assets are already absolute, so we only inject <base href> (the
# dashboard mounts at the origin root).
class SpaController < ActionController::Base
  skip_forgery_protection

  CLIENT_COOKIE = "carbide_client".freeze

  def show
    build = resolve_build
    if build && (html = build.read_index)
      pin_cookie(build)
      return render_spa(html)
    end

    render plain: "dashboard SPA not available; build + upload it to the static tier " \
                  "(scripts/build-client --mode control)",
           status: :not_found
  end

  private

  def registry
    @registry ||= ClientRegistry.new
  end

  def resolve_build
    # An explicit ?client= is a deliberate override (the build picker): honor
    # whatever family/sha it names.
    if (spec = params[:client].presence)
      return registry.resolve(spec)
    end

    # The pin cookie is shared across the whole origin: the control dashboard
    # (path "/") and every workspace mount (path "/w/<id>/") all use the same
    # cookie name, and a path="/" cookie is even sent to "/w/<id>/". So a pin
    # written by another mount must NOT be served here — only honor a cookie pin
    # that resolves within THIS pod's own family (carbide2-control); otherwise
    # serve the newest build of that family.
    fam = registry.default_family
    if (spec = request.cookies[CLIENT_COOKIE].presence)
      build = registry.resolve(spec)
      return build if build && build.name == fam
    end
    registry.newest(fam)
  rescue StandardError
    nil
  end

  # Pin the resolved build so subsequent history-mode loads stay on it until the
  # user picks another. Written at the Rack level because the app is api_only
  # (no ActionDispatch::Cookies middleware). Scoped to the mount path
  # (X-Forwarded-Prefix, "/" at the dashboard root) so it never collides with a
  # workspace mount's pin. Lax same-site keeps it on normal navigations.
  def pin_cookie(build)
    prefix = request.headers["X-Forwarded-Prefix"].to_s.sub(%r{/+\z}, "")
    path = prefix.empty? ? "/" : "#{prefix}/"
    response.set_cookie(CLIENT_COOKIE,
                        value: "#{build.name}@#{build.sha}", path: path, same_site: :lax)
  end

  # Inject <base href> (the dashboard mounts at the origin root, so "/") plus any
  # stripped prefix Traefik forwards. Asset URLs in the document are already
  # absolute (/clients/<family>/<sha>/...).
  def render_spa(html)
    prefix = request.headers["X-Forwarded-Prefix"].to_s.sub(%r{/+\z}, "")
    base_href = prefix.empty? ? "/" : "#{prefix}/"
    base_tag = %(<base href="#{ERB::Util.html_escape(base_href)}">)
    html = html.sub(/<head(\s[^>]*)?>/, "\\0\n  #{base_tag}")
    render html: html.html_safe, layout: false, content_type: "text/html"
  end
end
