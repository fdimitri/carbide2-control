# Computes the shell's phase for display (ADR-029 §4).
#
# Phase is derived, never stored. The operator watches only Workspace CRs, so
# anything it published about the shell pod would be a value latched at the
# last reconcile — and eviction, OOM kill, and drain are not CR writes. Rather
# than keep a field that nothing can refresh, this reads the one pod whose name
# Rails already knows how to compute.
class ShellStatus
  Result = Struct.new(:phase, :ready, :reason, :mode, keyword_init: true) do
    def to_h
      { phase: phase, ready: ready, reason: reason, mode: mode }
    end
  end

  # kubelet reasons that mean "this will not start on its own".
  TERMINAL_WAITING_REASONS = %w[
    ImagePullBackOff ErrImagePull InvalidImageName ErrImageNeverPull
    CreateContainerConfigError CreateContainerError CrashLoopBackOff
  ].freeze

  def initialize(project)
    @project = project
  end

  def call
    return result('Disabled', reason: nil) if @project.shell_disabled?
    return result('Idle',     reason: nil) if @project.shell_lazy? && desired_replicas.zero?

    pod = fetch_pod
    return result('Starting', reason: nil) if pod.nil?

    # A terminating pod is not a target: attaching to one races the StatefulSet
    # recreating ordinal 0, which is exactly the mid-rollout attach §4 refuses.
    return result('Starting', reason: nil) if pod.dig(:metadata, :deletionTimestamp).present?

    if (reason = failure_reason(pod))
      return result('Failed', reason: reason)
    end

    ready?(pod) ? result('Running', reason: nil) : result('Starting', reason: nil)
  end

  private

  def result(phase, reason:)
    Result.new(phase: phase, ready: phase == 'Running', reason: reason, mode: @project.shell_mode)
  end

  # The applied value, not the intent: an out-of-band CR edit should show up
  # here rather than be papered over by the DB. Falls back to the intent column
  # when the CR is unreachable.
  def desired_replicas
    return @desired_replicas if defined?(@desired_replicas)

    cr = CarbideControl::WorkspaceApi.get(@project)
    applied = cr&.dig(:spec, :shell, :replicas)
    @desired_replicas = applied.nil? ? @project.shell_replicas.to_i : applied.to_i
  rescue StandardError => e
    Rails.logger.warn("[ShellStatus] CR read failed for #{@project.id}: #{e.message}")
    @desired_replicas = @project.shell_replicas.to_i
  end

  def fetch_pod
    CarbideControl::Kube.core
                        .get_pod(@project.shell_pod_name, @project.namespace_name)
                        .to_h
  rescue Kubeclient::ResourceNotFoundError
    nil
  rescue StandardError => e
    Rails.logger.warn("[ShellStatus] pod read failed for #{@project.shell_pod_name}: #{e.message}")
    nil
  end

  def failure_reason(pod)
    return 'PodFailed' if pod.dig(:status, :phase).to_s == 'Failed'

    statuses = Array(pod.dig(:status, :containerStatuses)) +
               Array(pod.dig(:status, :initContainerStatuses))
    statuses.each do |cs|
      reason = cs.dig(:state, :waiting, :reason).to_s
      return reason if TERMINAL_WAITING_REASONS.include?(reason)
    end
    nil
  end

  def ready?(pod)
    Array(pod.dig(:status, :conditions)).any? do |c|
      c[:type].to_s == 'Ready' && c[:status].to_s == 'True'
    end
  end
end
