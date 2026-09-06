# Reads "what images exist" from the self-hosted Docker registry (ADR-025).
#
# Unauthenticated pull-only reads:
#   GET /v2/_catalog        -> { repositories: [...] }
#   GET /v2/<repo>/tags/list -> { tags: [...] }
#
# The registry is self-signed (mkcert), so control trusts REGISTRY_CA. The
# carbide repos are:
#   carbide2           (workspace: server-worker SHA pair, "<server>-<worker>")
#   carbide2-control   (control image)
#   carbide2-shell*    (shell images)
#
# Shell variants are separate repositories rather than tag prefixes (ADR-029
# §2): /v2/carbide2-shell-rust/tags/list answers "what versions of this variant
# exist" in one call, with no tag-string sorting and no retention policy shared
# between unrelated toolchains. Hence a prefix match here instead of a fixed
# allowlist — a new variant needs no code change to become visible.
module CarbideControl
  module ImageRegistry
    REPOS         = %w[carbide2 carbide2-control].freeze
    REPO_PREFIXES = %w[carbide2-shell].freeze

    module_function

    def known_repo?(repo)
      REPOS.include?(repo) || REPO_PREFIXES.any? { |p| repo == p || repo.start_with?("#{p}-") }
    end

    def base_url
      ENV.fetch('REGISTRY_URL').sub(%r{/\z}, '')
    rescue KeyError
      nil
    end

    def available?
      base_url.present?
    end

    def list_images
      raise 'REGISTRY_URL is not configured' unless available?

      catalog = get('/v2/_catalog')
      repos   = (catalog['repositories'] || []).select { |r| known_repo?(r) }
      repos.map { |repo| { repository: repo, tags: tags_for(repo) } }
    end

    def tags_for(repo)
      get("/v2/#{repo}/tags/list")['tags'] || []
    end

    def get(path)
      uri  = URI.parse("#{base_url}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      # Trust the self-signed registry via the SYSTEM trust store: the container
      # entrypoint installs REGISTRY_CA into /usr/local/share/ca-certificates and
      # runs update-ca-certificates (ADR-025). No per-client ca_file needed.
      req  = Net::HTTP::Get.new(uri.request_uri)
      resp = http.request(req)
      raise "registry #{path} returned #{resp.code}" unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body)
    end
  end
end
