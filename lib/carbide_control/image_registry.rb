# Reads "what images exist" from the self-hosted Docker registry (ADR-025).
#
# Unauthenticated pull-only reads:
#   GET /v2/_catalog        -> { repositories: [...] }
#   GET /v2/<repo>/tags/list -> { tags: [...] }
#
# The registry is self-signed (mkcert), so control trusts REGISTRY_CA. The
# three carbide repos are:
#   carbide2          (workspace: server-worker SHA pair, "<server>-<worker>")
#   carbide2-control  (control image)
#   carbide2-shell    (shell image)
module CarbideControl
  module ImageRegistry
    REPOS = %w[carbide2 carbide2-control carbide2-shell].freeze

    module_function

    def base_url
      ENV.fetch('REGISTRY_URL').sub(%r{/\z}, '')
    rescue KeyError
      nil
    end

    def available?
      !base_url.nil?
    end

    def list_images
      raise 'REGISTRY_URL is not configured' unless available?

      catalog = get('/v2/_catalog')
      repos   = (catalog['repositories'] || []).select { |r| REPOS.include?(r) }
      repos.map { |repo| { repository: repo, tags: tags_for(repo) } }
    end

    def tags_for(repo)
      get("/v2/#{repo}/tags/list")['tags'] || []
    end

    def get(path)
      uri  = URI.parse("#{base_url}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.ca_file = registry_ca_file if http.use_ssl? && registry_ca_file
      req  = Net::HTTP::Get.new(uri.request_uri)
      resp = http.request(req)
      raise "registry #{path} returned #{resp.code}" unless resp.is_a?(Net::HTTPSuccess)

      JSON.parse(resp.body)
    end

    # REGISTRY_CA is the PEM text; Net::HTTP wants a ca_file path. Write it to a
    # temp file once and reuse (the env is stable for the pod lifetime). A
    # single-file CA bundle is the only correct way to trust a self-signed
    # registry root — X509::Store#add_cert does NOT make a cert a trust anchor.
    def registry_ca_file
      @registry_ca_file ||= begin
        pem = ENV['REGISTRY_CA'].to_s.strip
        next nil if pem.empty?

        require 'tempfile'
        f = Tempfile.new(['carbide-registry-ca', '.pem'])
        f.write(pem)
        f.flush
        f.path
      end
    end
  end
end
