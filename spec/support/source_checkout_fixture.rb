# A real git repository for a workspace: an ordinary checkout (any directory
# name will do) with a committed HEAD on main and an origin remote, which is
# what registration and Orchestrator::GitWorktree.provision! need once a
# spec's run actually launches. Shared so every spec that needs one uses the
# same fixture instead of each re-deriving it slightly differently.
#
# `branches` adds local branches, each one commit ahead of main, so a run can
# start from something other than the default.
module SourceCheckoutFixture
  def create_source_checkout(branches: [], name: "repo")
    repository = File.join(Dir.mktmpdir("paneyard-repository"), name)
    FileUtils.mkdir_p(repository)
    git = ->(*args) { system("git", "-C", repository, *args, out: File::NULL, err: File::NULL) || raise("git #{args.join(' ')} failed") }
    git.call("init", "-b", "main")
    git.call("config", "user.email", "spec@example.test")
    git.call("config", "user.name", "Spec Fixture")
    File.write(File.join(repository, "README.md"), "source checkout fixture\n")
    git.call("add", "README.md")
    git.call("commit", "-m", "Initialize spec source checkout")
    git.call("remote", "add", "origin", "https://example.test/paneyard.git")
    branches.each do |branch|
      git.call("switch", "-q", "-c", branch)
      File.write(File.join(repository, "#{branch.tr('/', '-')}.txt"), "#{branch}\n")
      git.call("add", ".")
      git.call("commit", "-m", "Work on #{branch}")
      git.call("switch", "-q", "main")
    end
    repository
  end
end

RSpec.configure do |config|
  config.include SourceCheckoutFixture
end
