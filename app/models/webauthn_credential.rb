# A passkey/WebAuthn credential attached to a control-plane user (ADR-021).
#
# Non-resident only: the authenticator does not store the private key long-term;
# the credential ID (external_id) is the handle we send back on assertion.
class WebauthnCredential < ApplicationRecord
  belongs_to :user

  validates :external_id, presence: true, uniqueness: true
  validates :public_key, presence: true
  validates :nickname, presence: true, uniqueness: { scope: :user_id }

  # The public key is stored in COSE form (CBOR), as WebAuthn produces it.
  # webauthn-ruby consumes this directly for signature verification.
end
