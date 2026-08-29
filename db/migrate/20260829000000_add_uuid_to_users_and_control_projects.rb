class AddUuidToUsersAndControlProjects < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :uuid, :string
    add_column :control_projects, :uuid, :string

    User.find_each { |u| u.update_columns(uuid: SecureRandom.uuid) }
    ControlProject.find_each { |p| p.update_columns(uuid: SecureRandom.uuid) }

    add_index :users, :uuid, unique: true
    add_index :control_projects, :uuid, unique: true

    change_column_null :users, :uuid, false
    change_column_null :control_projects, :uuid, false
  end

  def down
    remove_column :control_projects, :uuid
    remove_column :users, :uuid
  end
end
