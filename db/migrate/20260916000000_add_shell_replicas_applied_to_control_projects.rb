# The applied projection's shadow: the last value ShellLifecycle actually wrote
# into spec.shell.replicas in the CR. Compared against shell_replicas to decide
# whether a stamp is needed, so a failed patch retries on the next report
# instead of waiting for a transition that may never come (ADR-029 §2's
# "applied output", now recorded rather than inferred).
#
# Left NULL for existing rows deliberately: it asserts nothing about the CR, so
# the first apply re-stamps and heals any divergence that already exists.
class AddShellReplicasAppliedToControlProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :control_projects, :shell_replicas_applied, :integer
  end
end
