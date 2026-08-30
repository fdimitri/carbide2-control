# WebAuthn Relying Party configuration (ADR-021).
#
# RP id/origin are derived from PUBLIC_URL_BASE (the browser-facing control-plane
# URL), which is already the authority the dashboard is served from. WebAuthn
# assertions fail at the browser if rpId/origin do not match the page origin, so
# this must be the same host the dashboard is actually reached at.
module CarbideControl
  module WebauthnConfig
    DEFAULT_RP_NAME = 'Carbide'.freeze
    DEFAULT_TTL     = 5.minutes.freeze

    module_function

    def rp_name
      ENV.fetch('WEBAUTHN_RP_NAME', DEFAULT_RP_NAME)
    end

    def rp_id
      # rpId is the registrable domain suffix of the origin. For a bare host
      # (no scheme/port) it is the host itself; for a host with port the port is
      # NOT part of rpId.
      host = origin_host
      host.split(':').first
    end

    def origin
      base = ENV.fetch('PUBLIC_URL_BASE', 'http://localhost:8080')
      base.sub(%r{/\z}, '')
    end

    def origin_host
      URI.parse(origin).host
    rescue URI::InvalidURIError
      'localhost'
    end

    def challenge_ttl
      ENV.fetch('WEBAUTHN_CHALLENGE_TTL', DEFAULT_TTL).to_i.seconds
    end
  end
end
