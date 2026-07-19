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
    spec = params[:client].presence || request.cookies[CLIENT_COOKIE].presence
    registry.resolve(spec)
  rescue StandardError
    nil
  end

  # Pin the resolved build so subsequent history-mode loads stay on it until the
  # user picks another. Written at the Rack level because the app is api_only
  # (no ActionDispatch::Cookies middleware). Lax same-site keeps it on normal
  # navigations.
  def pin_cookie(build)
    response.set_cookie(CLIENT_COOKIE,
                        value: "#{build.name}@#{build.sha}", path: "/", same_site: :lax)
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
