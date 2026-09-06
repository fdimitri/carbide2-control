# Default seeds for local dev. Idempotent.

admin = User.find_or_create_by!(email: 'admin@example.com') do |u|
  u.password = 'password'
  u.password_confirmation = 'password'
end
puts "[seed] admin user: #{admin.email}"

# ADR-016 §3 / ADR-025: workspace resource templates. Idempotent. The
# workspace-pod columns match the operator's current single-pod shape; the
# shell-pod half is seeded here only when the shell pod moves to -control
# (ADR-016 §7), not consumed today.
TEMPLATES = [
  { name: 'tiny',    cpu_req: '200m',  cpu_lim: '1',    mem_req: '512Mi', mem_lim: '1Gi',  storage: '1Gi',  default: false },
  { name: 'small',   cpu_req: '500m',  cpu_lim: '2',    mem_req: '512Mi', mem_lim: '2Gi',  storage: '4Gi',  default: false },
  { name: 'medium',  cpu_req: '1000m', cpu_lim: '2',    mem_req: '512Mi', mem_lim: '3Gi',  storage: '16Gi', default: false },
  { name: 'carbide', cpu_req: '1000m', cpu_lim: '2',    mem_req: '512Mi', mem_lim: '3Gi',  storage: '64Gi', default: true }
].freeze

TEMPLATES.each do |t|
  WorkspaceTemplate.find_or_create_by!(name: t[:name]) do |row|
    row.workspace_cpu_request    = t[:cpu_req]
    row.workspace_cpu_limit      = t[:cpu_lim]
    row.workspace_memory_request = t[:mem_req]
    row.workspace_memory_limit   = t[:mem_lim]
    row.storage_size             = t[:storage]
    row.is_default               = t[:default]
  end
end
puts "[seed] workspace templates: #{WorkspaceTemplate.pluck(:name).join(', ')}"

# ADR-029 §2 / OQ2. Global defaults; each is overridable per workspace by a
# nullable control_projects column. find_or_create_by! so an operator's edits
# survive re-seeding.
#
# The two clocks are deliberately not ordered the way an earlier draft assumed.
# max_report_time means "the worker is gone" and reclaiming an orphan is urgent
# — at a 30s heartbeat, 5m is ten consecutive misses. idle_timeout means "the
# worker is here and nobody wants a shell", which is a comfort call: 4h holds
# the shell through a working day's gaps and still reclaims it overnight.
SHELL_SETTINGS = {
  'workspace_shell_mode'            => 'eager',
  'workspace_shell_idle_timeout'    => 4 * 3600,
  'workspace_shell_max_report_time' => 300
}.freeze

SHELL_SETTINGS.each do |key, value|
  Setting.find_or_create_by!(key: key) { |row| row.value = value.to_s }
end
puts "[seed] shell settings: #{SHELL_SETTINGS.keys.join(', ')}"
