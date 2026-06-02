# Devise config — minimal API-only setup. Sessions and passwords only; no
# registrations controller (signup is handled by Api::SessionsController),
# no mailers (no confirmation/recovery email flows for now).

Devise.setup do |config|
  config.mailer_sender = 'no-reply@carbide.local'

  require 'devise/orm/active_record'

  config.case_insensitive_keys = [:email]
  config.strip_whitespace_keys = [:email]
  config.skip_session_storage = [:http_auth, :params_auth]
  config.stretches = Rails.env.test? ? 1 : 12
  config.reconfirmable = false
  config.password_length = 8..128
  config.email_regexp = /\A[^@\s]+@[^@\s]+\z/

  config.reset_password_within = 6.hours
  config.sign_out_via = :delete
  config.responder.error_status = :unprocessable_entity
  config.responder.redirect_status = :see_other

  # API-only: no warden navigational formats.
  config.navigational_formats = []
end
