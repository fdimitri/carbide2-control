# Durable key-value settings store (ADR-015). The source of truth for
# control-side policy knobs (token TTLs, session ceiling). Read at mint time
# with a short-TTL in-memory cache; env is bootstrap-only.
class Setting < ApplicationRecord
  validates :key, presence: true, uniqueness: true

  CACHE_TTL = 30  # seconds

  @cache = {}
  @cache_mutex = Mutex.new

  class << self
    # Fetch a setting. Resolution order: env (bootstrap) -> DB (authoritative,
    # cached) -> default. Integer-like values are coerced; everything else is
    # returned as the raw string.
    def get(key, default:, env: nil)
      if env && ENV[env].present?
        return coerce(ENV[env])
      end

      now = monotonic_now
      @cache_mutex.synchronize do
        entry = @cache[key]
        return entry[:value] if entry && (now - entry[:at]) < CACHE_TTL
      end

      row = find_by(key: key)
      value = row ? coerce(row.value) : default
      @cache_mutex.synchronize { @cache[key] = { value: value, at: monotonic_now } }
      value
    end

    def set(key, value)
      row = find_or_initialize_by(key: key)
      row.value = value.to_s
      row.save!
      @cache_mutex.synchronize { @cache[key] = { value: coerce(row.value), at: monotonic_now } }
      row.value
    end

    private

    def coerce(value)
      value = value.to_s
      value.match?(/\A-?\d+\z/) ? value.to_i : value
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
