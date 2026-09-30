# Orchestrator::GitWorktree.provision! (invoked by LaunchRunJob) requires a
# real "main" Git checkout with a committed HEAD and an origin remote under
# a workspace's root_path -- a bare Dir.mktmpdir isn't enough once a spec's
# run actually launches (as opposed to being created directly via Run.create!
# with a status that skips LaunchRunJob). Shared here so every spec that
# needs one uses the same fixture instead of each re-deriving it slightly
# differently.
module SourceCheckoutFixture
  def create_source_checkout
    parent = Dir.mktmpdir("paneyard-source-checkout")
    main = File.join(parent, "main")
    FileUtils.mkdir_p(main)
    system("git", "-C", main, "init", "-b", "main", out: File::NULL, err: File::NULL) || raise("could not initialize source checkout")
    system("git", "-C", main, "config", "user.email", "spec@example.test")
    system("git", "-C", main, "config", "user.name", "Spec Fixture")
    File.write(File.join(main, "README.md"), "source checkout fixture\n")
    system("git", "-C", main, "add", "README.md") || raise("could not stage source checkout")
    system("git", "-C", main, "commit", "-m", "Initialize spec source checkout", out: File::NULL, err: File::NULL) || raise("could not commit source checkout")
    system("git", "-C", main, "remote", "add", "origin", "https://example.test/paneyard.git") || raise("could not configure source checkout remote")
    parent
  end
end

RSpec.configure do |config|
  config.include SourceCheckoutFixture
end
