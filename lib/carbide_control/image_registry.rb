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

    # Accept headers for the OCI manifest chain. buildx wraps every image in an
    # OCI index (even single-platform), so a tag's manifest is an index whose
    # `manifests[]` holds the per-platform manifest + an attestation entry.
    INDEX_ACCEPT    = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'.freeze
    MANIFEST_ACCEPT = 'application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'.freeze
    BUILD_TIME_KEY  = 'CARBIDE_BUILD_TIME'.freeze

    # Process-local memo of build_time_for(repo, tag). The value is immutable
    # (the tag is a content-addressed SHA, so its build time can never change),
    # so a cache here is both correct and never needs invalidation. A new tag is
    # a new key. `nil` is cached too — "no build time" is a stable fact for a
    # foreign/old image, and caching it avoids re-walking a manifest that will
    # keep failing. Per-pod only: cross-replica coordination is pointless for an
    # immutable value, and the process lifetime bounds memory at 1 entry per tag.
    @cache       = {}
    @cache_mutex = Mutex.new

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

    # Tags as { tag, build_time } objects, newest build first. build_time is the
    # image's CARBIDE_BUILD_TIME env (baked at build); nil when a manifest walk
    # fails or the image predates the env. Sorted here so the workspace image
    # picker can render newest-first without re-walking.
    def tags_for(repo)
      raw = get("/v2/#{repo}/tags/list")['tags'] || []
      entries = raw.map { |tag| { tag: tag, build_time: build_time_for(repo, tag) } }
      entries.sort_by { |e| e[:build_time] || '' }.reverse
    end

    # Walk index → platform manifest → config blob and read CARBIDE_BUILD_TIME.
    # Returns the RFC3339 string, or nil on any miss (tag gone, foreign image).
    # Memoized: build time is immutable per (repo, tag).
    def build_time_for(repo, tag)
      key = "#{repo}:#{tag}"
      @cache_mutex.synchronize do
        return @cache[key] if @cache.key?(key)
      end

      value = fetch_build_time(repo, tag)
      @cache_mutex.synchronize { @cache[key] = value }
      value
    end

    # The actual (uncached) manifest walk. Isolated so build_time_for can memoize
    # without re-entering the cache path.
    def fetch_build_time(repo, tag)
      doc = get("/v2/#{repo}/manifests/#{tag}", accept: INDEX_ACCEPT)
      manifest = if doc['manifests']
                   digest = platform_manifest_digest(doc)
                   digest ? get("/v2/#{repo}/manifests/#{digest}", accept: MANIFEST_ACCEPT) : nil
                 else
                   doc # already a single manifest, not an index
                 end
      return nil unless manifest

      config_digest = manifest.dig('config', 'digest')
      return nil if config_digest.to_s.empty?

      config = get("/v2/#{repo}/blobs/#{config_digest}")
      env = config.dig('config', 'Env') || []
      entry = env.find { |e| e.start_with?("#{BUILD_TIME_KEY}=") }
      entry&.split('=', 2)&.last
    rescue StandardError
      nil
    end

    # From an index, pick the real platform manifest — skip the buildx
    # attestation-manifest entry (architecture/os "unknown").
    def platform_manifest_digest(index)
      entry = (index['manifests'] || []).find do |m|
        p = m['platform'] || {}
        p['architecture'] && p['architecture'] != 'unknown'
      end
      entry ||= (index['manifests'] || []).first
      entry && entry['digest']
    end

    def get(path, accept: nil)
      uri  = URI.parse("#{base_url}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      # Trust the self-signed registry via the SYSTEM trust store: the container
      # entrypoint installs REGISTRY_CA into /usr/local/share/ca-certificates and
      # runs update-ca-certificates (ADR-025). No per-client ca_file needed.
      req  = Net::HTTP::Get.new(uri.request_uri)
      req['Accept'] = accept if accept
      resp = http.request(req)
      raise "registry #{path} returned #{resp.code}" unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body)
    end
  end
end
