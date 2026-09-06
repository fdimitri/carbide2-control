# Default seeds for local dev. Idempotent.

admin = User.find_or_create_by!(email: 'admin@example.com') do |u|
  u.password = 'password'
  u.password_confirmation = 'password'
end
puts "[seed] admin user: #{admin.email}"

# ADR-016 §3 / ADR-025: workspace resource templates. Idempotent. The
# workspace-pod columns match the operator's current single-pod shape; the
# shell-pod half is ADR-016 §3's table, landing here with ADR-029 (£7).
TEMPLATES = [
  { name: 'tiny',    cpu_req: '200m',  cpu_lim: '1',    mem_req: '512Mi', mem_lim: '1Gi',  storage: '1Gi',  default: false,
    shell_cpu_req: '200m',  shell_cpu_lim: '1', shell_mem_req: '128Mi', shell_mem_lim: '1Gi' },
  { name: 'small',   cpu_req: '500m',  cpu_lim: '2',    mem_req: '512Mi', mem_lim: '2Gi',  storage: '4Gi',  default: false,
    shell_cpu_req: '1000m', shell_cpu_lim: '2', shell_mem_req: '256Mi', shell_mem_lim: '2Gi' },
  { name: 'medium',  cpu_req: '1000m', cpu_lim: '2',    mem_req: '512Mi', mem_lim: '3Gi',  storage: '16Gi', default: false,
    shell_cpu_req: '2000m', shell_cpu_lim: '4', shell_mem_req: '512Mi', shell_mem_lim: '4Gi' },
  { name: 'carbide', cpu_req: '1000m', cpu_lim: '2',    mem_req: '512Mi', mem_lim: '3Gi',  storage: '64Gi', default: true,
    shell_cpu_req: '2000m', shell_cpu_lim: '6', shell_mem_req: '512Mi', shell_mem_lim: '12Gi' }
].freeze

TEMPLATES.each do |t|
  WorkspaceTemplate.find_or_create_by!(name: t[:name]) do |row|
    row.workspace_cpu_request    = t[:cpu_req]
    row.workspace_cpu_limit      = t[:cpu_lim]
    row.workspace_memory_request = t[:mem_req]
    row.workspace_memory_limit   = t[:mem_lim]
    row.shell_cpu_request        = t[:shell_cpu_req]
    row.shell_cpu_limit          = t[:shell_cpu_lim]
    row.shell_memory_request     = t[:shell_mem_req]
    row.shell_memory_limit       = t[:shell_mem_lim]
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
