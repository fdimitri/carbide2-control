# ADR-029 §1: shell shape becomes template-driven, like the workspace pod's.
# ADR-007 proposed these columns on ProjectSetting and was never implemented;
# ADR-029 supersedes it and puts them here, where the workspace_* half already
# lives.
#
# Column defaults are the values project_pod.rb hardcodes today, so a template
# row not named in ADR-016 §3 keeps the shell it already had. The four named
# templates are backfilled to §3's table below.
class AddShellResourcesToWorkspaceTemplates < ActiveRecord::Migration[8.1]
  # ADR-016 §3, request/limit. §3 writes tiny/small/medium RAM as MB and carbide
  # as MiB; read as the Mi/Gi the rest of the schema uses.
  SHELL_RESOURCES = {
    'tiny'    => %w[200m 1 128Mi 1Gi],
    'small'   => %w[1000m 2 256Mi 2Gi],
    'medium'  => %w[2000m 4 512Mi 4Gi],
    'carbide' => %w[2000m 6 512Mi 12Gi]
  }.freeze

  def change
    change_table :workspace_templates, bulk: true do |t|
      t.string :shell_cpu_request,    null: false, default: '50m'
      t.string :shell_cpu_limit,      null: false, default: '6'
      t.string :shell_memory_request, null: false, default: '128Mi'
      t.string :shell_memory_limit,   null: false, default: '8Gi'
    end

    reversible do |dir|
      dir.up do
        SHELL_RESOURCES.each do |name, (cpu_req, cpu_lim, mem_req, mem_lim)|
          execute <<~SQL.squish
            UPDATE workspace_templates SET
              shell_cpu_request    = #{connection.quote(cpu_req)},
              shell_cpu_limit      = #{connection.quote(cpu_lim)},
              shell_memory_request = #{connection.quote(mem_req)},
              shell_memory_limit   = #{connection.quote(mem_lim)}
            WHERE name = #{connection.quote(name)}
          SQL
        end
      end
    end
  end
end
