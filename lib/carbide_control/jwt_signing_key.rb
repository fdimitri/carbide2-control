# frozen_string_literal: true

require 'openssl'
require 'base64'
require 'digest'

module CarbideControl
  # Loads the RSA signing key and derives its public JWKS representation.
  #
  # ADR-015 asymmetric signing: control holds the PRIVATE key and is the only
  # minter; pods hold only the public key, fetched from /.well-known/jwks.json.
  # The `kid` is a stable fingerprint of the public key (base64url SHA-256 of
  # the DER SPKI), never a counter, so it survives restarts and mints.
  module JwtSigningKey
    KEY_ENV      = 'JWT_SIGNING_KEY'.freeze
    KEY_FILE_ENV = 'JWT_SIGNING_KEY_FILE'.freeze

    module_function

    def private_key
      @private_key ||= load_key
    end

    def kid
      @kid ||= fingerprint(private_key.public_key)
    end

    # Public JWKS entry (never the private half).
    def public_jwk
      pub = private_key.public_key
      {
        kty: 'RSA',
        use: 'sig',
        alg: 'RS256',
        kid: kid,
        n: urlsafe(pub.n.to_s(2)),
        e: urlsafe(pub.e.to_s(2))
      }
    end

    # JWKS document. Structured as a list from day one so rotation (two active
    # keys) needs no shape change.
    def jwks
      { keys: [public_jwk] }
    end

    def load_key
      pem =
        if (path = ENV[KEY_FILE_ENV].to_s.strip) && !path.empty?
          File.read(path)
        elsif (inline = ENV[KEY_ENV].to_s.strip) && !inline.empty?
          inline
        end

      if pem
        OpenSSL::PKey::RSA.new(pem)
      elsif Rails.env.production?
        raise "#{KEY_FILE_ENV} or #{KEY_ENV} must be set in production"
      else
        warn('[carbide-control] no JWT signing key configured; generating an ephemeral dev key')
        OpenSSL::PKey::RSA.generate(2048)
      end
    end

    def fingerprint(pub)
      Base64.urlsafe_encode64(Digest::SHA256.digest(pub.to_der), padding: false)
    end

    def urlsafe(bin)
      Base64.urlsafe_encode64(bin, padding: false)
    end
  end
end
