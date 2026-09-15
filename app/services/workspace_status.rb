# WorkspaceStatus — the lifecycle status to report for a workspace.
#
# Mirrors ShellStatus: the value is DERIVED at read time from the two things
# that actually know it, never stored in a column that something would have to
# keep in step.
#
# Two sources, one order:
#
#   1. The CR's `status.phase`, written by the operator. This is the truth
#      about the pod: Provisioning / Ready / Failed / Terminating. The operator
#      is the only component that observes the Deployment, and it writes to the
#      CR's status subresource rather than the control DB (it is DB-free by
#      design).
#
#   2. The control row's own `status` column, but ONLY for the states the CR
#      cannot express — a failed CR write, or a delete in flight. The column
#      cannot express anything else: `create` sets 'provisioning' and nothing
#      ever advances it, so falling back to it renders "provisioning" forever.
#      That is indistinguishable from having no status, which is why
#      'provisioning' is deliberately not in CONTROL_ONLY_PHASES.
#
#   3. Otherwise nil. An absent status is honest; a stale one is a claim that
#      was never true. Callers render nil as "unknown" rather than substituting.
class WorkspaceStatus
  # Control-row states that mean something even when the CR says nothing.
  CONTROL_ONLY_PHASES = %w[failed terminating].freeze

  def self.call(control_status:, cr: nil)
    new(control_status: control_status, cr: cr).call
  end

  # control_status : the ControlProject row's status column (any case/whitespace).
  # cr             : the Workspace CR as a Hash or a Kubeclient::Resource, or nil
  #                  when the CR could not be read.
  def initialize(control_status:, cr: nil)
    @control_status = control_status
    @cr             = cr
  end

  # The lowercase phase to report, or nil when nothing knows.
  def call
    phase = cr_phase
    return phase if phase

    column = normalize(@control_status)
    return column if CONTROL_ONLY_PHASES.include?(column)

    nil
  end

  private

  # `status.phase` from the CR, symbol- or string-keyed, or nil.
  def cr_phase
    normalize(fetch(fetch(@cr, :status), :phase))
  end

  # Accepts either key style: Kubeclient resources are symbol-accessible, but a
  # plain Hash parsed from JSON has string keys, and both reach here.
  #
  # Hash-likeness is checked rather than `respond_to?(:[])`, because String and
  # Array both answer `[]` — and `"Ready"[:phase]` raises TypeError, which would
  # turn a malformed CR into a 500 instead of "unknown".
  def fetch(maybe_hash, key)
    return nil unless hash_like?(maybe_hash)

    maybe_hash[key] || maybe_hash[key.to_s]
  end

  def hash_like?(obj)
    # nil is excluded explicitly: `nil.respond_to?(:to_h)` is true (Ruby 2.4+),
    # so leaving it to the respond_to? check would send nil into `[]`.
    return false if obj.nil? || obj.is_a?(Array) || obj.is_a?(String)

    obj.is_a?(Hash) || obj.respond_to?(:to_h)
  end

  def normalize(value)
    s = value.to_s.strip.downcase
    s.empty? ? nil : s
  end
end
