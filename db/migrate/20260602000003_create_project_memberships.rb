class CreateProjectMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :project_memberships do |t|
      t.references :user,             null: false, foreign_key: true
      t.references :control_project,  null: false, foreign_key: true
      t.string :role, null: false, default: 'member'
      t.timestamps
    end

    add_index :project_memberships, [:user_id, :control_project_id], unique: true,
              name: 'index_memberships_on_user_and_project'
  end
end
