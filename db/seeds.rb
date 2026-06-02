# Default seeds for local dev. Idempotent.

admin = User.find_or_create_by!(email: 'admin@example.com') do |u|
  u.password = 'password'
  u.password_confirmation = 'password'
end
puts "[seed] admin user: #{admin.email}"
