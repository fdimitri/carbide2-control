# A named resource preset (ADR-016 §3, ADR-025). Control-owned and seeded;
# each control deployment can edit its own template values. Applying a template
# resolves to concrete resources that are written into the Workspace CR spec —
# the operator never reads this table, it only sees the resolved spec.
class WorkspaceTemplate < ApplicationRecord
  validates :name, presence: true, uniqueness: true
  validates :workspace_cpu_request, :workspace_cpu_limit,
            :workspace_memory_request, :workspace_memory_limit,
            :shell_cpu_request, :shell_cpu_limit,
            :shell_memory_request, :shell_memory_limit,
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

  # The same, for the shell pod (ADR-029 §1). Separate from #resources because
  # the two pods are sized for different work: the workspace pod runs Rails and
  # the worker, the shell pod is where compiles happen.
  def shell_resources
    {
      requests: {
        cpu:    shell_cpu_request,
        memory: shell_memory_request
      },
      limits: {
        cpu:    shell_cpu_limit,
        memory: shell_memory_limit
      }
    }
  end
end
