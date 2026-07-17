# A registered target project the orchestrator can be pointed at (e.g.
# simple-retail-planner). Runs launched from the ops UI pick one of these
# instead of the app being wired to a single hardcoded
# WORKFLOW_TARGET_ROOT env var -- see Run#target_root, which still holds
# the actual path a launched run's supervisor process gets, just sourced
# from here now.
class Workspace < ApplicationRecord
  has_many :runs, dependent: :restrict_with_error
  has_many :workspace_memory_entries, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: true
  validates :root_path, presence: true, uniqueness: true

  def self.default
    order(:created_at).first
  end
end
