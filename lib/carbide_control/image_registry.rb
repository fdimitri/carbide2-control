# Reads "what images exist" from the self-hosted Docker registry (ADR-025).
#
# Unauthenticated pull-only reads:
#   GET /v2/_catalog        -> { repositories: [...] }
#   GET /v2/<repo>/tags/list -> { tags: [...] }
#
# REGISTRY_PATH is an optional namespace between host and repo name (a GitLab
# registry needs group/project). It goes INSIDE every /v2/<namespaced-repo>/…
# path, not into REGISTRY_URL. Blank keeps the flat self-hosted shape.
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
    VERSION_LABEL   = 'org.carbide.version'.freeze
    CODENAME_LABEL  = 'org.carbide.codename'.freeze

    # Process-local memo of image_meta_for(repo, tag). The value is immutable
    # (the tag is a content-addressed SHA), so a cache here is both correct and
    # never needs invalidation. A new tag is a new key. nil is cached too —
    # "unknown" is a stable fact for a foreign/old image. Per-pod only: the
    # process lifetime bounds memory at 1 entry per tag.
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

    # Optional namespace between host and image name (blank => flat registry).
    def registry_path
      ENV['REGISTRY_PATH'].to_s.gsub(%r{\A/+|/+\z}, '')
    end

    # Repo name as it appears in the /v2 API path (namespace included).
    def api_repo(repo)
      ns = registry_path
      ns.empty? ? repo : "#{ns}/#{repo}"
    end

    # Inverse: strip the namespace off a repo name from the API/catalog.
    def bare_repo(repo)
      ns = registry_path
      return repo if ns.empty?

      repo.start_with?("#{ns}/") ? repo.sub("#{ns}/", '') : repo
    end

    def available?
      base_url.present?
    end

    # REGISTRY_CATALOG controls whether we trust /v2/_catalog:
    #   auto (default) — probe it, fall back when absent (works for both a
    #                    self-hosted registry and GitLab, at one failed GET).
    #   yes            — use it; fall back only if the call itself errors.
    #   no             — never call it (GitLab): go straight to the known set.
    def catalog_mode
      ENV['REGISTRY_CATALOG'].to_s.strip.downcase
    end

    # Repository names are returned BARE (namespacing is an internal detail of
    # the /v2 paths); the client matches on "carbide2" / "carbide2-shell*".
    def list_images
      raise 'REGISTRY_URL is not configured' unless available?

      repos = case catalog_mode
              when 'no'  then fallback_repos
              when 'yes' then catalog_repos || fallback_repos
              else            catalog_repos || fallback_repos   # auto
              end
      repos.map { |repo| { repository: repo, tags: tags_for(repo) } }
    end

    # The Docker v2 catalog. Self-hosted registries expose it; GitLab does not,
    # so a nil here means "fall back to the fixed known set".
    def catalog_repos
      catalog = get('/v2/_catalog')
      (catalog['repositories'] || []).map { |r| bare_repo(r) }.select { |r| known_repo?(r) }
    rescue StandardError
      nil
    end

    # Without _catalog we can only name repos we already know. Shell variants are
    # open-ended (undiscoverable this way); REGISTRY_REPOS lists any extra ones.
    def fallback_repos
      extra = ENV['REGISTRY_REPOS'].to_s.split(',').map(&:strip).reject(&:empty?)
      (REPOS + extra).uniq
    end

    # Tags as { tag, build_time, version, codename } objects, newest build first.
    # build_time is the image's CARBIDE_BUILD_TIME env; version/codename are the
    # org.carbide.* OCI labels. All come from one config-blob walk, memoized per
    # (repo, tag). Sorted here so the workspace image picker renders newest-first.
    def tags_for(repo)
      raw = get("/v2/#{api_repo(repo)}/tags/list")['tags'] || []
      entries = raw.map do |tag|
        meta = image_meta_for(repo, tag) || {}
        { tag: tag,
          build_time: meta[:build_time],
          version:    meta[:version],
          codename:   meta[:codename] }
      end
      entries.sort_by { |e| e[:build_time] || '' }.reverse
    end

    # Walk index → platform manifest → config blob once, returning
    # { build_time:, version:, codename: } (nil fields absent/unknown). Memoized:
    # all three are immutable per content-addressed tag.
    def image_meta_for(repo, tag)
      key = "#{repo}:#{tag}"
      @cache_mutex.synchronize do
        return @cache[key] if @cache.key?(key)
      end

      value = fetch_image_meta(repo, tag)
      @cache_mutex.synchronize { @cache[key] = value }
      value
    end

    # The actual (uncached) manifest walk.
    def fetch_image_meta(repo, tag)
      doc = get("/v2/#{api_repo(repo)}/manifests/#{tag}", accept: INDEX_ACCEPT)
      manifest = if doc['manifests']
                   digest = platform_manifest_digest(doc)
                   digest ? get("/v2/#{api_repo(repo)}/manifests/#{digest}", accept: MANIFEST_ACCEPT) : nil
                 else
                   doc # already a single manifest, not an index
                 end
      return nil unless manifest

      config_digest = manifest.dig('config', 'digest')
      return nil if config_digest.to_s.empty?

      config = get("/v2/#{api_repo(repo)}/blobs/#{config_digest}")
      inner = config['config'] || {}

      env    = inner['Env'] || []
      labels = inner['Labels'] || {}
      bt     = env.find { |e| e.start_with?("#{BUILD_TIME_KEY}=") }

      {
        build_time: bt&.split('=', 2)&.last,
        version:    labels[VERSION_LABEL],
        codename:   labels[CODENAME_LABEL],
      }
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
