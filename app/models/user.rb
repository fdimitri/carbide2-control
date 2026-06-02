class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :validatable

  has_many :project_memberships, dependent: :destroy
  has_many :control_projects, through: :project_memberships
end
