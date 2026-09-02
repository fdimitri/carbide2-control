class AddTemplateNameToControlProjects < ActiveRecord::Migration[8.1]
  def up
    add_column :control_projects, :template_name, :string

    # Existing workspaces predate templates; assign the 'small' preset so they
    # have a known, editable home rather than a confusing null/custom state.
    small = WorkspaceTemplate.find_by(name: 'small')
    ControlProject.where(template_name: nil).update_all(template_name: 'small') if small
  end

  def down
    remove_column :control_projects, :template_name
  end
end
