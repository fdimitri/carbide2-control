# ADR-029 §2: the durable half of shell lifecycle state.
#
# Three layers, deliberately not collapsed into one column: shell_terminals /
# shell_last_report_at / shell_idle_since are the durable INPUT written by
# worker reports, shell_replicas is the INTENT derived from them, and
# spec.shell.replicas in the CR is the applied OUTPUT.
class AddShellToControlProjects < ActiveRecord::Migration[8.1]
  def change
    change_table :control_projects, bulk: true do |t|
      t.string   :shell_mode, null: false, default: 'eager'
      t.integer  :shell_replicas, null: false, default: 0
      t.integer  :shell_terminals, null: false, default: 0
      t.datetime :shell_last_report_at
      # The falling edge of the refcount, NOT the last report. Null means no
      # falling edge has been observed and condition 1 cannot fire (§2).
      t.datetime :shell_idle_since
      t.string   :shell_image_repo
      t.string   :shell_image_tag
      # Nullable per-workspace overrides; null means inherit the global Setting.
      t.integer  :shell_idle_timeout
      t.integer  :shell_max_report_time
    end

    # The sweep's driving query: lazy workspaces whose intent is currently 1.
    add_index :control_projects, %i[shell_mode shell_replicas],
              name: 'index_control_projects_on_shell_sweep'

    # The 'eager' default above exists only to backfill rows that predate the
    # column. Left in place it would pre-empt ControlProject's `||=` and the
    # global Setting would never be consulted for a new workspace (§2).
    change_column_default :control_projects, :shell_mode, from: 'eager', to: nil
  end
end
