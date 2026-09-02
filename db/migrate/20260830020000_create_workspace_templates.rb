class CreateWorkspaceTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :workspace_templates do |t|
      t.string :name, null: false
      t.string :workspace_cpu_request,    null: false, default: '200m'
      t.string :workspace_cpu_limit,      null: false, default: '1'
      t.string :workspace_memory_request, null: false, default: '512Mi'
      t.string :workspace_memory_limit,   null: false, default: '1Gi'
      t.string :storage_size,             null: false, default: '1Gi'
      t.boolean :is_default, null: false, default: false
      t.timestamps
    end

    add_index :workspace_templates, :name, unique: true
  end
end
