# ADR-029 §1: shell shape becomes template-driven, like the workspace pod's.
# ADR-007 proposed these columns on ProjectSetting and was never implemented;
# ADR-029 supersedes it and puts them here, where the workspace_* half already
# lives.
#
# Defaults are the values project_pod.rb hardcodes today, so migrating an
# existing deployment changes nothing about the shell it gets.
class AddShellResourcesToWorkspaceTemplates < ActiveRecord::Migration[8.1]
  def change
    change_table :workspace_templates, bulk: true do |t|
      t.string :shell_cpu_request,    null: false, default: '50m'
      t.string :shell_cpu_limit,      null: false, default: '6'
      t.string :shell_memory_request, null: false, default: '128Mi'
      t.string :shell_memory_limit,   null: false, default: '8Gi'
    end
  end
end
