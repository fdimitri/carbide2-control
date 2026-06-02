class CreateControlProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :control_projects do |t|
      t.string  :name,        null: false
      t.references :owner,    null: false, foreign_key: { to_table: :users }
      t.string  :status,      null: false, default: 'pending'
      t.string  :last_error
      t.timestamps
    end

    add_index :control_projects, :status
  end
end
