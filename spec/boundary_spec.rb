require "rails_helper"

# The orchestrator/runner boundary (Orchestrator::Runner): everything that
# touches the machine runs happen on -- herdr, git, files under a workspace,
# process signals, spawning commands -- lives under
# app/services/orchestrator/runner/, and the rest of the app reaches it only
# through a runner object (Runner.for(workspace)). This fails when something
# outside reaches for the machine directly, or for one of the runner's
# internals instead of its interface.
RSpec.describe "Orchestrator/runner boundary" do
  RUNNER_FILES = [ "app/services/orchestrator/runner.rb", %r{\Aapp/services/orchestrator/runner/} ].freeze

  FORBIDDEN = {
    "herdr (use the runner)" => /\bHerdr\b/,
    "a runner internal (use Runner.for(workspace))" => /\bRunner::(?!Error\b|Unreachable\b|LaunchError\b)[A-Z]/,
    "running a command" => /\bOpen3\b|\bsystem\(|%x[({\[]|\bIO\.popen\b|\bspawn\(|\bProcess\.spawn\b/,
    "git" => /["']git["']/,
    "a process signal" => /\bProcess\.kill\b/,
    "a socket" => /\bUNIXSocket\b|\bSocket\./,
    "the filesystem" => Regexp.union(
      /\bFileUtils\b/, /\bDir\./, /\bIO\.(read|write|binread|binwrite)\b/,
      /\bFile\.(read|write|binread|binwrite|open|exist\?|directory\?|file\?|executable\?|stat|size|mtime|chmod|delete|unlink|rename|symlink|readlines|foreach|utime|realpath)\b/,
      /\.(exist\?|directory\?|realpath|mkpath|rmtree)(?![\w?])/
    )
  }.freeze

  # Orchestrator-side code that shells out for reasons of its own, not the
  # runner's machine.
  ALLOWED = {
    # curl to the GitHub API, to mint installation tokens.
    "app/services/orchestrator/github_app_auth.rb" => [ "running a command" ],
    # The sandbox's own guards, which both sides consult: `ps` to confirm a
    # pid is a fake agent before the runner signals it.
    "app/services/orchestrator/sandbox.rb" => [ "running a command" ]
  }.freeze

  def code_lines(path)
    File.readlines(path).each_with_index.filter_map do |line, index|
      stripped = line.strip
      next if stripped.start_with?("#") || stripped.start_with?("<%#")

      [ index + 1, line ]
    end
  end

  it "keeps every reach into the runner's machine behind Orchestrator::Runner" do
    files = Dir.glob("app/**/*.{rb,erb}", base: Rails.root).reject do |path|
      RUNNER_FILES.any? { |pattern| pattern.is_a?(Regexp) ? pattern.match?(path) : pattern == path }
    end
    expect(files).not_to be_empty

    violations = files.flat_map do |path|
      allowed = ALLOWED.fetch(path, [])
      code_lines(Rails.root.join(path)).flat_map do |number, line|
        FORBIDDEN.filter_map do |what, pattern|
          "#{path}:#{number} reaches for #{what}: #{line.strip}" if !allowed.include?(what) && line.match?(pattern)
        end
      end
    end

    expect(violations).to be_empty, violations.join("\n")
  end
end
