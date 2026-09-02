# A named resource preset (ADR-016 §3, ADR-025). Control-owned and seeded;
# each control deployment can edit its own template values. Applying a template
# resolves to concrete resources that are written into the Workspace CR spec —
# the operator never reads this table, it only sees the resolved spec.
class WorkspaceTemplate < ApplicationRecord
  validates :name, presence: true, uniqueness: true
  validates :workspace_cpu_request, :workspace_cpu_limit,
            :workspace_memory_request, :workspace_memory_limit,
            :storage_size, presence: true

  # The resolved workspace-pod resources block, ready to merge into CR spec.
  def resources
    {
      requests: {
        cpu:    workspace_cpu_request,
        memory: workspace_memory_request
      },
      limits: {
        cpu:    workspace_cpu_limit,
        memory: workspace_memory_limit
      }
    }
  end
end
