# An operator setting, kept here so it can be entered over /mcp/admin
# (update_settings) and applies straight away. Only the keys in KEYS exist;
# a blank value is no row.
#
#   projects_dir          where create_workspace puts a project when it is
#                         given no path (a directory on the runner's machine)
#   default_github_owner  the GitHub user or organization create_workspace
#                         creates or clones repositories under when it is
#                         given no owner (else the gh user)
class Setting < ApplicationRecord
  KEYS = %w[projects_dir default_github_owner].freeze

  validates :key, presence: true, uniqueness: true, inclusion: { in: KEYS }

  def self.[](key)
    raise ArgumentError, "unknown setting #{key}" unless KEYS.include?(key.to_s)

    find_by(key: key.to_s)&.value.presence
  end

  # Sets it, or with a blank value clears it.
  def self.[]=(key, value)
    raise ArgumentError, "unknown setting #{key}" unless KEYS.include?(key.to_s)

    if value.to_s.strip.empty?
      where(key: key.to_s).delete_all
    else
      find_or_initialize_by(key: key.to_s).update!(value: value.to_s.strip)
    end
  end

  def self.to_h
    KEYS.index_with { |key| self[key] }
  end
end
