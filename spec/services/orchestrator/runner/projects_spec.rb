require "rails_helper"
require "open3"

# Real git in a temp directory, with a fake gh (spec/support/fake_gh.rb) whose
# "GitHub" is bare repositories there too: what a project ends up with is only
# meaningful against real git, and no spec may reach the real GitHub.
RSpec.describe Orchestrator::Runner::Projects do
  let(:tmp) { File.realpath(Dir.mktmpdir("projects")) }
  let(:parent) { File.join(tmp, "Source").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:target) { File.join(parent, "lists") }
  let!(:gh) { use_fake_gh!(File.join(tmp, "fake-gh")) }

  around do |example|
    saved = ENV.to_h.slice("GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM")
    example.run
  ensure
    %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM].each { |key| ENV.delete(key) }
    ENV.update(saved)
    FileUtils.remove_entry(tmp) if File.exist?(tmp)
  end

  before { git_identity!(name: "Operator", email: "operator@example.test") }

  def git_identity!(name: nil, email: nil)
    config = File.join(tmp, "gitconfig")
    File.write(config, [ ("[user]" if name || email), ("\tname = #{name}" if name), ("\temail = #{email}" if email) ].compact.join("\n") + "\n")
    ENV["GIT_CONFIG_GLOBAL"] = config
    ENV["GIT_CONFIG_NOSYSTEM"] = "1"
  end

  def git(dir, *args)
    output, error, status = Open3.capture3("git", "-C", dir.to_s, *args)
    raise "git #{args.join(' ')} failed: #{error}" unless status.success?

    output.strip
  end

  def codes(result)
    result.fetch("problems").map { |problem| problem.fetch("code") }
  end

  def gh_writes
    gh.calls.select { |argv| argv.first == "repo" }
  end

  def create(**arguments)
    described_class.create(**{ path: target, name: "lists", owner: "operator" }.merge(arguments))
  end

  # An existing local repository with one commit on `branch`.
  def local_repository(branch: "main", origin: nil)
    FileUtils.mkdir_p(target)
    git(target, "init", "--quiet", "--initial-branch=#{branch}")
    File.write(File.join(target, "app.rb"), "puts 1\n")
    git(target, "add", ".")
    git(target, "commit", "--quiet", "-m", "existing work")
    git(target, "remote", "add", "origin", origin) if origin
    target
  end

  describe ".check_projects_dir" do
    it "accepts an existing writable directory, expanded, and refuses anything else" do
      expect(described_class.check_projects_dir("#{parent}/")).to eq("path" => parent, "problems" => [])
      expect(described_class.check_projects_dir("~")["path"]).to eq(File.expand_path("~"))
      expect(codes(described_class.check_projects_dir("Source"))).to eq(%w[path_not_absolute])
      expect(codes(described_class.check_projects_dir(File.join(tmp, "nope")))).to eq(%w[projects_dir_missing])
    end
  end

  describe "a brand-new project" do
    it "makes the directory, main with a first commit, and the GitHub repository as its origin with main pushed" do
      result = create(description: "A public mailing list.")

      expect(result).to include("created" => true, "local" => "absent", "repository_path" => target,
                                "github_repository" => "operator/lists", "visibility" => "private", "default_base_branch" => "main",
                                "done" => %w[create_directory git_init first_commit create_github_repository push_branch],
                                "github_url" => "https://github.com/operator/lists", "origin_url" => gh.remote("operator/lists"))
      expect(git(target, "branch", "--show-current")).to eq("main")
      expect(git(target, "log", "--format=%s %an", "main")).to eq("Start lists Operator")
      expect(git(target, "ls-files").lines.map(&:strip)).to contain_exactly("README.md", "AGENTS.md")
      expect(File.read(File.join(target, "README.md"))).to eq("# lists\n\nA public mailing list.\n")
      expect(git(gh.remote("operator/lists"), "rev-parse", "main")).to eq(git(target, "rev-parse", "main"))
      expect(gh_writes).to eq([ [ "repo", "create", "operator/lists", "--private", "--source", target, "--remote", "origin",
                                  "--description", "A public mailing list." ] ])
      expect(Orchestrator::Runner::Repositories.check(target)).to include("default_base_branch" => "main", "problems" => [])
    end

    it "takes another owner it may create under, and the visibility" do
      gh.update("owners" => { "Gembani" => "Organization" }, "memberships" => [ "Gembani" ])

      expect(create(owner: "Gembani", visibility: "public")).to include("created" => true, "github_repository" => "Gembani/lists")
      expect(gh_writes.last).to include("Gembani/lists", "--public")
      expect(described_class.check(path: File.join(parent, "other"), name: "other")).to include("owner" => "operator", "problems" => [])
    end

    it "removes the directory it made, and only that, when GitHub refuses the repository" do
      gh.update("create" => "fail")
      File.write(File.join(parent, "keep.txt"), "mine\n")

      result = create

      expect(result).to include("created" => false, "remaining" => { "local_repository" => nil, "github_repository" => nil })
      expect(result["message"]).to include("gh repo create operator/lists failed", "was removed again", "Name already exists")
      expect(File.exist?(target)).to be(false)
      expect(File.read(File.join(parent, "keep.txt"))).to eq("mine\n")
    end

    it "keeps everything once the GitHub repository exists, and a second call finishes the push" do
      gh.update("create" => "push_fail")

      result = create

      expect(result).to include("created" => false, "done" => %w[create_directory git_init first_commit create_github_repository],
                                "remaining" => { "local_repository" => target, "github_repository" => "operator/lists" })
      expect(result["message"]).to include("push refused", "Nothing was removed", "call create_workspace again",
                                           "git -C #{target} push -u origin main", "register_workspace")
      expect(result["message"]).not_to match(/\n\./)

      FileUtils.rm(File.join(gh.remote("operator/lists"), "hooks", "pre-receive"))
      retried = create
      expect(retried).to include("created" => true, "local" => "repository", "done" => %w[push_branch])
      expect(git(gh.remote("operator/lists"), "rev-parse", "main")).to eq(git(target, "rev-parse", "main"))
    end

    it "removes what it made when the first commit cannot be made" do
      git(tmp, "config", "--file", ENV["GIT_CONFIG_GLOBAL"], "commit.gpgsign", "true")
      git(tmp, "config", "--file", ENV["GIT_CONFIG_GLOBAL"], "gpg.program", "/nonexistent/gpg")

      result = create

      expect(result).to include("created" => false, "remaining" => { "local_repository" => nil, "github_repository" => nil })
      expect(File.exist?(target)).to be(false)
      expect(gh_writes).to be_empty
    end
  end

  describe "a project only on GitHub" do
    it "clones it, whoever owns it, and takes its default branch" do
      gh.update("owners" => { "someone" => "User" })
      gh.seed("someone/lists", branch: "trunk")

      result = create(owner: "someone")

      expect(result).to include("created" => true, "local" => "absent", "done" => %w[clone], "default_base_branch" => "trunk",
                                "origin_url" => gh.remote("someone/lists"))
      expect(git(target, "log", "--format=%s")).to eq("seed")
      expect(gh_writes).to eq([ [ "repo", "clone", "someone/lists", target, "--", "--quiet" ] ])
    end

    it "removes what a failed clone left" do
      gh.seed("operator/lists")
      gh.update("clone" => "fail")

      result = create

      expect(result["message"]).to include("gh repo clone operator/lists failed", "removed again")
      expect(File.exist?(target)).to be(false)
    end
  end

  describe "a project that exists locally" do
    it "turns a plain directory into the repository, committing only the README and AGENTS.md, and keeping its own README" do
      FileUtils.mkdir_p(target)
      File.write(File.join(target, "README.md"), "# Lists, mine\n")
      File.write(File.join(target, ".env"), "SECRET=1\n")

      result = create

      expect(result).to include("created" => true, "local" => "directory",
                                "done" => %w[git_init first_commit create_github_repository push_branch])
      expect(result["notes"]).to eq([ "1 file(s) already in #{target} are left untracked: commit what belongs in the repository." ])
      expect(git(target, "ls-files").lines.map(&:strip)).to contain_exactly("README.md", "AGENTS.md")
      expect(git(target, "show", "main:README.md")).to eq("# Lists, mine")
      expect(git(target, "status", "--porcelain")).to eq("?? .env")
    end

    it "gives a repository with no commits its first one on main, staged files left out" do
      FileUtils.mkdir_p(target)
      git(target, "init", "--quiet", "--initial-branch=master")
      File.write(File.join(target, "wip.rb"), "x\n")
      git(target, "add", "wip.rb")

      result = create

      expect(result).to include("created" => true, "local" => "unborn", "default_base_branch" => "main",
                                "done" => %w[first_commit create_github_repository push_branch])
      expect(git(target, "ls-tree", "--name-only", "main").lines.map(&:strip)).to contain_exactly("README.md", "AGENTS.md")
      expect(git(target, "status", "--porcelain")).to eq("A  wip.rb")
    end

    it "puts a repository with no origin on GitHub, pushing its own default branch" do
      local_repository(branch: "master")

      result = create

      expect(result).to include("created" => true, "local" => "repository", "default_base_branch" => "master",
                                "done" => %w[create_github_repository push_branch])
      expect(git(gh.remote("operator/lists"), "log", "--format=%s", "master")).to eq("existing work")
      expect(git(target, "log", "--format=%s")).to eq("existing work")
    end

    it "pushes the default branch to an origin that lacks it, and touches nothing GitHub otherwise" do
      bare = File.join(tmp, "elsewhere.git")
      git(tmp, "init", "--quiet", "--bare", bare)
      local_repository(origin: bare)

      expect(create).to include("created" => true, "done" => %w[push_branch])
      expect(create).to include("created" => true, "done" => [])
      expect(gh.calls).to be_empty
    end

    it "notes, and pushes nothing, when it cannot reach origin" do
      local_repository(origin: File.join(tmp, "gone.git"))

      result = create

      expect(result).to include("created" => true, "done" => [])
      expect(result["notes"].first).to start_with("Could not check whether origin has main")
    end

    it "keeps an existing directory as it is when GitHub refuses, and carries on when called again" do
      local_repository
      gh.update("create" => "fail")

      failed = create
      expect(failed).to include("created" => false, "remaining" => { "local_repository" => target, "github_repository" => nil })
      expect(failed["message"]).to include("Nothing was removed", "call create_workspace again")
      expect(git(target, "log", "--format=%s")).to eq("existing work")

      gh.update("create" => "ok")
      expect(create).to include("created" => true, "done" => %w[create_github_repository push_branch])
    end

    it "refuses a repository with no origin when GitHub has one by that name" do
      local_repository
      gh.seed("operator/lists")

      result = create
      expect(codes(result)).to eq(%w[github_repository_exists])
      expect(result["problems"].first["message"]).to include("git -C #{target} remote add origin https://github.com/operator/lists.git")
      expect(gh_writes).to be_empty
    end

    it "refuses a directory inside another checkout, or a linked worktree, pointing at register_workspace" do
      local_repository
      FileUtils.mkdir_p(File.join(target, "sub"))
      git(target, "worktree", "add", "--quiet", "-b", "side", File.join(tmp, "side"))

      expect(codes(create(path: File.join(target, "sub")))).to eq(%w[inside_checkout])
      result = create(path: File.join(tmp, "side"))
      expect(codes(result)).to eq(%w[inside_checkout])
      expect(result["problems"].first["message"]).to include("the checkout #{target}", "register_workspace")
    end
  end

  describe "checks, refusing before doing anything" do
    def refused(**arguments)
      result = create(**arguments)
      expect(result["created"]).to be(false)
      expect(gh_writes).to be_empty
      result
    end

    it "refuses a name GitHub or a directory could not have, a relative path, a missing parent, a file, and a bad visibility" do
      expect(codes(refused(name: "-bad name"))).to eq(%w[name_invalid])
      expect(codes(refused(name: "x.git"))).to eq(%w[name_invalid])
      expect(codes(refused(path: "projects/lists"))).to eq(%w[path_not_absolute])
      expect(codes(refused(path: File.join(tmp, "missing", "lists")))).to eq(%w[parent_missing])
      File.write(File.join(parent, "file"), "x")
      expect(codes(refused(path: File.join(parent, "file")))).to eq(%w[path_not_directory])
      expect(codes(refused(visibility: "secret"))).to eq(%w[visibility_invalid])
      expect(Dir.children(parent)).to eq([ "file" ])
    end

    it "refuses when git has no identity for a first commit, but not when none is needed" do
      git_identity!(name: "Operator")

      result = refused
      expect(codes(result)).to eq(%w[git_identity_missing])
      expect(result["problems"].first["message"]).to include("git config --global user.email")

      gh.seed("operator/lists")
      expect(create).to include("created" => true, "done" => %w[clone])
    end

    # A plugin reinstall swaps the checkout a running Paneyard was started
    # in, leaving its working directory deleted.
    it "still works when this process's working directory has been deleted" do
      gone = File.join(tmp, "gone")
      Dir.mkdir(gone)
      result = Dir.chdir(gone) do
        Dir.rmdir(gone)
        create
      end

      expect(result).to include("created" => true, "problems" => [])
    end

    it "reports a git failure as itself, not as a missing identity" do
      allow(Open3).to receive(:capture3).and_call_original
      allow(Open3).to receive(:capture3).with("git", "config", "--get", "user.name", chdir: Dir.home)
        .and_return([ "", "fatal: something else broke\n", instance_double(Process::Status, success?: false, exitstatus: 128) ])

      result = refused
      expect(codes(result)).to eq(%w[git_error])
      expect(result["problems"].first["message"]).to eq("Could not read git's user.name: fatal: something else broke")
    end

    it "refuses when gh is missing or not logged in" do
      allow(Orchestrator::Runner::GitHub).to receive(:executable).and_return(File.join(tmp, "no-such-gh"))
      expect(codes(refused)).to eq(%w[gh_missing])

      allow(Orchestrator::Runner::GitHub).to receive(:executable).and_return(gh.executable)
      gh.update("authenticated" => false)
      expect(codes(refused)).to eq(%w[gh_unauthenticated])
    end

    it "refuses to create under an owner GitHub does not have, another user, or an organization you are not in" do
      gh.update("owners" => { "someone" => "User", "Gembani" => "Organization" })

      expect(codes(refused(owner: "nobody-here"))).to eq(%w[owner_missing])
      expect(codes(refused(owner: "someone"))).to eq(%w[owner_not_you])
      expect(codes(refused(owner: "Gembani"))).to eq(%w[owner_not_member])
      expect(codes(refused(owner: "bad owner"))).to eq(%w[owner_invalid])
    end

    it "returns every problem at once" do
      FileUtils.mkdir_p(target)
      gh.seed("operator/lists")

      expect(codes(refused(visibility: "secret"))).to eq(%w[visibility_invalid github_repository_exists])
    end

    it "never calls GitHub, nor makes anything, in a sandbox" do
      ENV["PANEYARD_SANDBOX_ROOT"] = tmp
      ENV["PANEYARD_SANDBOX"] = "1"

      expect(codes(refused)).to eq(%w[outside_sandbox])
      expect(gh.calls).to be_empty
      expect(File.exist?(target)).to be(false)
    ensure
      ENV.delete("PANEYARD_SANDBOX")
      ENV.delete("PANEYARD_SANDBOX_ROOT")
    end
  end
end
