require "test_helper"

# WorkspaceStatus resolves the lifecycle phase from the CR first, the control
# row second, and says nothing when neither knows.
#
# These pin the behaviour that made the dashboard read "provisioning" forever:
# the row's column is set once at create and never advanced, so falling back to
# it unconditionally is a claim rather than an observation.
class WorkspaceStatusTest < ActiveSupport::TestCase
  def resolve(control_status:, cr: nil)
    WorkspaceStatus.call(control_status: control_status, cr: cr)
  end

  # --- the CR is the truth when it says anything ---------------------------

  test "reports the CR phase when the operator has written one" do
    cr = { status: { phase: "Ready" } }
    assert_equal "ready", resolve(control_status: "provisioning", cr: cr)
  end

  test "normalizes case and whitespace" do
    cr = { status: { phase: "  Provisioning \n" } }
    assert_equal "provisioning", resolve(control_status: "failed", cr: cr)
  end

  test "reads a string-keyed CR as well as a symbol-keyed one" do
    cr = { "status" => { "phase" => "Failed" } }
    assert_equal "failed", resolve(control_status: "provisioning", cr: cr)
  end

  test "the CR outranks the control column even for a control-only state" do
    # A CR phase means the operator is alive and reporting; a stale 'failed'
    # column from a create-time error must not override that.
    cr = { status: { phase: "Ready" } }
    assert_equal "ready", resolve(control_status: "failed", cr: cr)
  end

  # --- the control column, only where the CR cannot speak ------------------

  test "reports a failed CR write when there is no CR" do
    # create's rescue path: the CR may not exist at all, so no phase can.
    assert_equal "failed", resolve(control_status: "failed", cr: nil)
  end

  test "reports terminating when there is no CR" do
    assert_equal "terminating", resolve(control_status: "terminating", cr: nil)
  end

  test "'provisioning' is NOT reported from the column" do
    # The bug: nothing advances this column, so it would render forever.
    assert_nil resolve(control_status: "provisioning", cr: nil)
  end

  test "'pending' (the column default) is not reported" do
    assert_nil resolve(control_status: "pending", cr: nil)
  end

  # --- nothing knows -------------------------------------------------------

  test "nil when the CR has no status yet" do
    assert_nil resolve(control_status: "provisioning", cr: { spec: {} })
  end

  test "nil when the CR status has no phase" do
    assert_nil resolve(control_status: "provisioning", cr: { status: { message: "applying" } })
  end

  test "nil when the CR phase is empty or blank" do
    assert_nil resolve(control_status: "provisioning", cr: { status: { phase: "   " } })
  end

  test "nil when the CR could not be read and the column says nothing useful" do
    assert_nil resolve(control_status: nil, cr: nil)
    assert_nil resolve(control_status: "", cr: nil)
  end

  # --- malformed input is not an exception ---------------------------------

  test "a CR that is not hash-like yields nil rather than raising" do
    assert_nil resolve(control_status: "provisioning", cr: "not a hash")
  end

  test "a CR whose status is not hash-like does not raise, and falls to the column" do
    assert_equal "failed", resolve(control_status: "failed", cr: { status: "Ready" })
  end

  test "a CR whose status is not hash-like with nothing in the column is nil" do
    assert_nil resolve(control_status: "provisioning", cr: { status: "Ready" })
  end
end
