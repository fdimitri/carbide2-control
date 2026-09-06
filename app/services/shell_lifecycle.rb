# The writers of shell_terminals / shell_idle_since / shell_replicas
# (ADR-029 §2 and §5), kept together deliberately: the falling-edge latch is
# only correct if EVERY writer maintains it, and scattering these across
# controllers is how that stops being true.
#
# Layering, which the column names alone do not make obvious:
#   shell_terminals / shell_last_report_at / shell_idle_since  — durable input
#   shell_replicas                                             — derived intent
#   spec.shell.replicas                                        — applied output
#
# The CR is written only on an intent TRANSITION, so a heartbeating worker does
# not produce a CR write per report.
class ShellLifecycle
  class << self
    # A worker report: terminal create/destroy, or a periodic keep-alive.
    def report!(project, terminals:)
      terminals = terminals.to_i
      terminals = 0 if terminals.negative?

      apply(project) do |p|
        p.shell_last_report_at = Time.current
        latch_idle(p, terminals)
        p.shell_terminals = terminals
        p.shell_replicas  = 1 if terminals.positive? && p.shell_lazy?
      end
    end

    # A worker asking for a handle. Demand in its own right: the cold-start path
    # must not wait for the follow-up `n: 1` release, or it races its own idle
    # clock.
    def demand!(project)
      apply(project) do |p|
        p.shell_last_report_at = Time.current
        p.shell_idle_since     = nil
        p.shell_replicas       = 1 if p.shell_lazy?
      end
    end

    # A mode change from the dashboard. Not a plain column write: eager -> lazy
    # has to arm the latch, because nothing was tracking the falling edge while
    # the mode was eager and a null latch means condition 1 can never fire.
    def set_mode!(project, mode)
      raise ArgumentError, "unknown shell mode #{mode.inspect}" unless ControlProject::SHELL_MODES.include?(mode)

      apply(project) do |p|
        previous     = p.shell_mode
        p.shell_mode = mode
        next if previous == mode

        case mode
        when 'lazy'
          if p.shell_terminals.positive?
            p.shell_replicas = 1
          else
            # Eligible for idle-down immediately: the clock starts at the flip.
            # Assigned, not ||=: a latch left over from an earlier lazy period
            # is unreadable under eager and must be corrected here, or the
            # sweep sees hours of "idle" that never happened.
            p.shell_idle_since = Time.current
            # disabled -> lazy creates the object at lazy's default of 0;
            # eager -> lazy leaves a running shell up until the timeout.
            p.shell_replicas = 0 if previous == 'disabled'
          end
        when 'eager'
          # Belt-and-braces; the operator holds 1 under eager regardless.
          p.shell_replicas = 1
        end
      end
    end

    # One sweep pass (ADR-029 §5). Uncoordinated by design: every control
    # replica runs its own, staggered by SHELL_SWEEP_OFFSET. Redundant passes
    # are idempotent.
    def sweep!(logger: Rails.logger)
      scope = ControlProject.where(shell_mode: 'lazy', shell_replicas: 1)
      scaled = 0

      scope.pluck(:id).each do |id|
        project = ControlProject.find_by(id: id)
        next if project.nil?

        # Re-evaluated INSIDE the transaction that writes the intent. Deciding
        # from values read at the start of the pass would let a cold start
        # landing mid-sweep be overwritten by a `replicas: 0` decided against a
        # refcount that is no longer current.
        changed = apply(project) do |p|
          next unless p.shell_lazy? && p.shell_replicas == 1

          if worker_gone?(p)
            # Scaling down on liveness must also reset the refcount. Leaving a
            # dead worker's claim in place means the falling edge never re-arms,
            # the latch stays null, and condition 1 can never fire for this
            # workspace again.
            p.shell_terminals  = 0
            p.shell_idle_since = Time.current
            p.shell_replicas   = 0
            logger.info("[shell-sweep] ws-#{p.id} scaling down: worker silent")
          elsif idle_long_enough?(p)
            p.shell_replicas = 0
            logger.info("[shell-sweep] ws-#{p.id} scaling down: idle")
          end
        end

        scaled += 1 if changed
      end

      scaled
    end

    private

    # §2's latch rules. The asymmetry is the point: demand nulls the latch
    # immediately, but only a TRANSITION to zero sets it. Re-latching on every
    # `n: 0` heartbeat would restart the idle clock forever, which is the exact
    # failure this column exists to avoid.
    def latch_idle(project, terminals)
      if terminals.positive?
        project.shell_idle_since = nil
      elsif project.shell_terminals.to_i.positive?
        project.shell_idle_since = Time.current
      end
    end

    # Condition 1: genuinely no terminals for long enough, measured from the
    # falling edge rather than the last report so a healthy worker heartbeating
    # `n: 0` does not reset its own idle clock.
    def idle_long_enough?(project)
      return false unless project.shell_terminals.to_i.zero?

      since = project.shell_idle_since
      return false if since.nil?

      Time.current - since > project.effective_shell_idle_timeout
    end

    # Condition 2: the worker has stopped reporting, so it is frozen or dead
    # regardless of what its last `n` claimed. A frozen worker with a stale
    # `n: 3` is not three live terminals; it is an orphaned shell.
    def worker_gone?(project)
      last = project.shell_last_report_at
      return false if last.nil?

      Time.current - last > project.effective_shell_max_report_time
    end

    # Runs the block against a locked row, then stamps the CR only if the
    # intent actually moved. Returns true when the intent changed.
    def apply(project)
      transitioned = false

      project.with_lock do
        before = project.shell_replicas
        yield project
        project.save!
        transitioned = project.shell_replicas != before
      end

      stamp_replicas(project) if transitioned
      transitioned
    end

    def stamp_replicas(project)
      CarbideControl::WorkspaceApi.merge_patch(
        project, spec: { shell: { replicas: project.shell_replicas.to_i } }
      )
    rescue StandardError => e
      # The DB intent is the durable value; the next transition or a manual
      # re-apply restamps. Failing the worker's request over this would be worse.
      Rails.logger.error("[ShellLifecycle] CR stamp failed for ws-#{project.id}: #{e.message}")
    end
  end
end
