# Control-plane view of a project. The workspace pod has its own per-project
# row in its own DB; this one is the cluster-wide registry.
#
# Lifecycle:
#   pending      — row just created, Workspace CR not yet written
#   provisioning — CR written, operator working
#   ready        — workspace pod is Ready, URL available
#   failed       — operator reports Failed in CR status
#   terminating  — destroy initiated, CR + namespace teardown in progress
class ControlProject < ApplicationRecord
  belongs_to :owner, class_name: 'User'
  has_many :project_memberships, dependent: :destroy
  has_many :users, through: :project_memberships

  validates :name, presence: true, length: { maximum: 64 },
                   format: { with: /\A[a-zA-Z0-9 _-]+\z/, message: 'may only contain letters, numbers, spaces, hyphens, underscores' }

  STATUSES = %w[pending provisioning ready failed terminating].freeze
  validates :status, inclusion: { in: STATUSES }

  after_initialize { self.status ||= 'pending' }

  # Stable control-side identity (the workspace uuid; == project uuid under
  # 1:1), carried in tokens as workspace_uuid/project_uuid.
  before_validation :assign_uuid, on: :create

  # Derived names. Kept here (not in the operator) so Rails can render URLs
  # without consulting the cluster. The operator MUST honor the same scheme.
  def namespace_name
    "ws-#{id}"
  end

  def release_name
    "ws-#{id}"
  end

  def ingress_path_prefix
    "/w/#{id}"
  end

  private

  def assign_uuid
    self.uuid ||= SecureRandom.uuid
  end
end
