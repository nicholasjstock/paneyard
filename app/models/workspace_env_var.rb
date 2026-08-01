# A workspace-scoped environment variable, discovered live by a worker (e.g.
# a bundle install workaround) and merged into every future spawned worker's
# and run command's process environment for this workspace -- see
# Orchestrator::WorkspaceEnvVars. Unlike WorkspaceMemoryEntry, there is no
# supersede history: a name has exactly one current value, and recording it
# again simply overwrites the value in place.
class WorkspaceEnvVar < ApplicationRecord
  belongs_to :workspace

  validates :name, :value, :evidence_ref, :recorded_by, presence: true
  validates :name, format: { with: /\A[A-Za-z_][A-Za-z0-9_]*\z/, message: "must be a valid environment variable name" }
  validates :name, uniqueness: { scope: :workspace_id }

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
