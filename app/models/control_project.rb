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

  # `name` is display-only: namespace_name / release_name / shell_name /
  # ingress_path_prefix are all derived from the numeric id (ws-<id>, /w/<id>),
  # never from `name`. So there is no identifier-safety reason to constrain its
  # character set — only presence and a sane display length. If it is ever used
  # in a machine context (label/path/URL), escape it at that point instead.
  validates :name, presence: true, length: { maximum: 64 }

  STATUSES = %w[pending provisioning ready failed terminating].freeze
  validates :status, inclusion: { in: STATUSES }

  # ADR-029 §2. eager: always up. lazy: 0↔1 on demand. disabled: no object.
  SHELL_MODES = %w[eager lazy disabled].freeze
  validates :shell_mode, inclusion: { in: SHELL_MODES }

  after_initialize { self.status ||= 'pending' }

  # Stable control-side identity (the workspace uuid; == project uuid under
  # 1:1), carried in the token's aud/project_uuid claims.
  before_validation :assign_uuid, on: :create
  before_validation :assign_default_template, on: :create
  before_validation :assign_default_shell_mode, on: :create

  # The assigned resource preset (DB-authoritative). Resolves to the current
  # WorkspaceTemplate row; nil means "no preset assigned" (custom).
  def template
    template_name.present? ? WorkspaceTemplate.find_by(name: template_name) : nil
  end

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

  # --- shell (ADR-029) ---------------------------------------------------

  # Placeholder name, known wrong: a workspace can hold several projects, so
  # this asserts a 1:1 that does not hold, and the identifier should be the
  # project UUID rather than the numeric id. Survives only because project UUID
  # currently equals workspace UUID. Pending the ADR-030 identity decision.
  def shell_name
    "ws-#{id}-shell"
  end

  # The StatefulSet's ordinal-0 pod. Derivable rather than discoverable, which
  # is the whole reason §3 picked a StatefulSet: nothing has to publish this
  # name anywhere for it to stay correct.
  def shell_pod_name
    "#{shell_name}-0"
  end

  def shell_disabled?
    shell_mode == 'disabled'
  end

  def shell_lazy?
    shell_mode == 'lazy'
  end

  def effective_shell_idle_timeout
    shell_idle_timeout || Setting.get('workspace_shell_idle_timeout',
                                      default: 4 * 3600,
                                      env: 'WORKSPACE_SHELL_IDLE_TIMEOUT')
  end

  def effective_shell_max_report_time
    shell_max_report_time || Setting.get('workspace_shell_max_report_time',
                                         default: 300,
                                         env: 'WORKSPACE_SHELL_MAX_REPORT_TIME')
  end

  def effective_shell_image_repo
    shell_image_repo.presence || Setting.get('workspace_shell_image_repo',
                                             default: 'carbide2-shell',
                                             env: 'WORKSPACE_SHELL_IMAGE_REPO')
  end

  def effective_shell_image_tag
    shell_image_tag.presence || Setting.get('workspace_shell_image_tag',
                                            default: 'dev',
                                            env: 'WORKSPACE_SHELL_IMAGE_TAG')
  end

  private

  def assign_uuid
    self.uuid ||= SecureRandom.uuid
  end

  def assign_default_template
    self.template_name ||= WorkspaceTemplate.find_by(is_default: true)&.name
  end

  # The resolved mode is recorded per-workspace and then stamped into the CR,
  # so the operator never has to know the global default existed (ADR-025).
  def assign_default_shell_mode
    self.shell_mode ||= Setting.get('workspace_shell_mode',
                                    default: 'eager',
                                    env: 'WORKSPACE_SHELL_MODE').to_s
    self.shell_replicas = shell_mode == 'eager' ? 1 : 0
  end
end
