# Verifies the worker's identity for the shell endpoints (ADR-029 §6).
#
# The worker presents a projected ServiceAccount token with audience
# `carbide-control`, mounted and rotated by kubelet and bound to the workspace
# pod. It dies when the pod dies, so there is no expiry or revocation to
# hand-roll. Control checks it with a TokenReview.
#
# The workspace identity comes out of the TOKEN, not the URL: a token issued to
# ws-7 authenticates as `system:serviceaccount:ws-7:ws-7`, so the caller cannot
# name a different workspace in the path and be believed.
module CarbideControl
  class WorkerAuth
    AUDIENCE = ENV.fetch('WORKER_TOKEN_AUDIENCE', 'carbide-control').freeze

    # A cached review lets a deleted worker keep authenticating until it
    # expires. The direction that costs is a stale `n: 0` release latching the
    # falling edge on a healthy workspace, so this stays far below the idle
    # timeout (ADR-029 OQ3).
    CACHE_TTL = Integer(ENV.fetch('WORKER_TOKEN_CACHE_TTL', '60'))

    Identity = Struct.new(:namespace, :service_account, :username, keyword_init: true) do
      # ws-7 -> 7. Nil for any SA that isn't a workspace's own.
      def project_id
        m = namespace.to_s.match(/\Aws-(\d+)\z/)
        m && Integer(m[1])
      end
    end

    @cache = {}
    @mutex = Mutex.new

    class << self
      # Returns an Identity, or nil when the token is absent/invalid.
      def identify(token)
        return nil if token.blank?

        digest = Digest::SHA256.hexdigest(token)
        now    = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        @mutex.synchronize do
          entry = @cache[digest]
          return entry[:identity] if entry && (now - entry[:at]) < CACHE_TTL
        end

        identity = review(token)
        # Only positive results are cached. A nil here is either a bad token or
        # a transient TokenReview failure, and caching the latter locks a
        # healthy worker out for CACHE_TTL. The only caller is our own worker,
        # so there is no bad-token flood a negative cache would be protecting
        # the apiserver from.
        if identity
          @mutex.synchronize do
            @cache[digest] = { identity: identity, at: Process.clock_gettime(Process::CLOCK_MONOTONIC) }
            # Unbounded growth would otherwise track every token ever seen.
            @cache.shift while @cache.size > 4096
          end
        end
        identity
      end

      private

      def review(token)
        result = Kube.post_subresource(
          '/apis/authentication.k8s.io/v1/tokenreviews',
          {
            apiVersion: 'authentication.k8s.io/v1',
            kind:       'TokenReview',
            spec:       { token: token, audiences: [AUDIENCE] }
          }
        )

        status = result['status'] || {}
        return nil unless status['authenticated']

        # The API server echoes the audiences the token is actually valid for.
        # A token minted for a different audience must not pass here even if it
        # authenticates, or any pod's default SA token would be accepted.
        audiences = status['audiences'] || []
        return nil unless audiences.include?(AUDIENCE)

        username = status.dig('user', 'username').to_s
        m = username.match(%r{\Asystem:serviceaccount:([^:]+):(.+)\z})
        return nil unless m

        # §6: audience AND SA identity. The workspace pod's SA is named after
        # its namespace (ws-N/ws-N); the exec SA (ws-N/ws-N-exec) lives in the
        # same namespace and must not be able to report as the worker.
        return nil unless m[1] == m[2]

        Identity.new(namespace: m[1], service_account: m[2], username: username)
      rescue StandardError => e
        Rails.logger.warn("[WorkerAuth] TokenReview failed: #{e.class}: #{e.message}")
        nil
      end
    end
  end
end
