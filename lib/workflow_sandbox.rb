require "digest"
require "tmpdir"

# A worktree-local, throwaway instance of this app: its own port, sqlite files,
# pid files and a fake herdr, so a change can be exercised end to end before
# it reaches the long-running production instance (bin/service).
#
# Plain Ruby on purpose -- bin/sandbox, bin/preflight and script/fake_herdr use
# it without booting Rails. Inside Rails, Orchestrator::Sandbox is the switch
# the application code consults.
module WorkflowSandbox
  ENABLED_ENV_VAR = "WORKFLOW_SANDBOX".freeze
  ROOT_ENV_VAR = "WORKFLOW_SANDBOX_ROOT".freeze

  module_function

  def enabled?(env = ENV)
    env[ENABLED_ENV_VAR] == "1"
  end

  def root(env = ENV)
    File.expand_path(env.fetch(ROOT_ENV_VAR) { File.expand_path("../tmp/sandbox", __dir__) })
  end

  # Derived from the root rather than living under it: a Unix socket path is
  # capped at 104 bytes on macOS, and a worktree's tmp/ is already close to
  # that. Deterministic so Rails and the scripts agree without passing it.
  def herdr_socket_path(root = self.root)
    File.join(Dir.tmpdir, "workflow-sandbox-#{Digest::SHA256.hexdigest(root)[0, 12]}.sock")
  end

  def inside?(path, root = self.root)
    target = canonical(path)
    base = canonical(root)
    target == base || target.start_with?("#{base}/")
  end

  # /var and /tmp are symlinks on macOS, so compare real paths where they
  # exist. A path that does not exist yet is judged by its nearest existing
  # ancestor.
  def canonical(path)
    expanded = File.expand_path(path.to_s)
    existing = expanded
    existing = File.dirname(existing) until File.exist?(existing) || existing == "/"
    File.join(File.realpath(existing), expanded.delete_prefix(existing)).chomp("/")
  end
end
