class AddWorkspaceImageTagToControlProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :control_projects, :workspace_image_tag, :string
  end
end
