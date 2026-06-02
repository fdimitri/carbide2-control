class ProjectMembership < ApplicationRecord
  belongs_to :user
  belongs_to :control_project

  ROLES = %w[owner member viewer].freeze
  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :control_project_id }

  after_initialize { self.role ||= 'member' }
end
