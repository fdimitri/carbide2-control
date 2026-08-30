class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :validatable

  has_many :project_memberships, dependent: :destroy
  has_many :control_projects, through: :project_memberships

  # Stable control-side identity, carried in the token's sub claim (user:<uuid>).
  # Local integer PKs never leave the DB.
  before_validation :assign_uuid, on: :create

  private

  def assign_uuid
    self.uuid ||= SecureRandom.uuid
  end
end
