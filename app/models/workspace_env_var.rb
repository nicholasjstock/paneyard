# A workspace-scoped environment variable, discovered live by a worker (e.g.
# a bundle install workaround) and merged into every future spawned worker's
# and run command's process environment for this workspace -- see
# Orchestrator::WorkspaceEnvVars. There is no supersede history: a name has
# exactly one current value, and recording it again simply overwrites the
# value in place.
class WorkspaceEnvVar < ApplicationRecord
  belongs_to :workspace

  validates :name, :value, :evidence_ref, :recorded_by, presence: true
  validates :name, format: { with: /\A[A-Za-z_][A-Za-z0-9_]*\z/, message: "must be a valid environment variable name" }
  validates :name, uniqueness: { scope: :workspace_id }
  # This value becomes a literal Process.spawn env entry, never a shell-
  # sourced line -- confirmed live: a recorded "${TMPDIR:-/tmp}/x" reaches a
  # future worker's $FOO as that exact unexpanded literal string, not a
  # resolved path, because env var values are substituted verbatim rather
  # than re-parsed as shell syntax. Reject the shapes that only make sense
  # if something were about to re-expand them, so this is caught at record
  # time instead of silently breaking whatever reads the variable later.
  validates :value, format: {
    without: /[$`]/,
    message: "must be a fully resolved literal value, not shell syntax (e.g. use an absolute path like /tmp/foo, " \
      "not $TMPDIR/foo or `cmd`) -- this is set directly as the process environment, never shell-expanded"
  }

  def as_json(*)
    {
      name: name,
      value: value,
      evidenceRef: evidence_ref,
      recordedBy: recorded_by,
      updatedAt: updated_at.iso8601(3)
    }
  end
end
