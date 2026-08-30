# A one-time, short-lived challenge for a WebAuthn ceremony (ADR-021).
#
# Stored in Postgres (not Rails.cache) because control Rails is stateless and
# may be horizontally scaled: registration/assertion "begin" on one pod must be
# consumable by "complete" on another.
class WebauthnChallenge < ApplicationRecord
  validates :challenge, presence: true, uniqueness: true

  scope :unexpired, -> { where(consumed: false).where('expires_at > ?', Time.current) }

  def self.issue!(challenge:, ttl: 5.minutes)
    create!(challenge: challenge, expires_at: Time.current + ttl)
  end

  def consume!
    update!(consumed: true)
  end
end
