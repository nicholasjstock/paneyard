require "rails_helper"
require "open3"

# Real git, the fake gh (spec/support/fake_gh.rb) in place of GitHub.
RSpec.describe McpTools::CreateWorkspaceTool do
  let(:tmp) { File.realpath(Dir.mktmpdir("create-workspace")) }
  let(:source) { File.join(tmp, "Source").tap { |dir| FileUtils.mkdir_p(dir) } }
  let!(:gh) { use_fake_gh!(File.join(tmp, "fake-gh")) }

  around do |example|
    saved = ENV.to_h.slice("GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM")
    example.run
  ensure
    %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM].each { |key| ENV.delete(key) }
    ENV.update(saved)
    FileUtils.remove_entry(tmp) if File.exist?(tmp)
  end

  before do
    config = File.join(tmp, "gitconfig")
    File.write(config, "[user]\n\tname = Operator\n\temail = operator@example.test\n")
    ENV["GIT_CONFIG_GLOBAL"] = config
    ENV["GIT_CONFIG_NOSYSTEM"] = "1"
    gh.update("owners" => { "Gembani" => "Organization" }, "memberships" => [ "Gembani" ])
    Setting["projects_dir"] = source
  end

  # An existing workspace, as the operator has: its checkout under Source.
  let!(:zendin) { Workspace.create!(name: "zendin-back", repository_path: File.join(source, "zendin-back"), default_base_branch: "main") }

  def call(**arguments)
    described_class.call(server_context: {}, **arguments)
  end

  def git(dir, *args)
    output, error, status = Open3.capture3("git", "-C", dir.to_s, *args)
    raise "git #{args.join(' ')} failed: #{error}" unless status.success?

    output.strip
  end

  def problem_codes(response)
    response.structured_content[:problems].map { |problem| problem[:code] }
  end

  def gh_writes
    gh.calls.select { |argv| argv.first == "repo" }
  end

  it "creates a new project in the projects directory, registers it, and returns it as list_workspaces does" do
    response = nil
    expect { response = call(name: "lists", owner: "Gembani", description: "Mailing lists for lists.gembani.com") }
      .to change(Workspace, :count).by(1)

    path = File.join(source, "lists")
    expect(response.error?).to be(false)
    expect(response.structured_content).to include(
      name: "lists", repositoryPath: path, defaultBaseBranch: "main", isDefault: false, activeRuns: 0, lobby: nil,
      originUrl: gh.remote("Gembani/lists"), githubUrl: "https://github.com/Gembani/lists",
      githubRepository: "Gembani/lists", visibility: "private",
      steps: %w[create_directory git_init first_commit create_github_repository push_branch], notes: []
    )
    expect(response.structured_content.keys).to include(*McpTools::ListWorkspacesTool.present(zendin).keys.map { |key| key.to_s.camelize(:lower).to_sym })
    expect(Workspace.find_by!(name: "lists")).to have_attributes(repository_path: path, default_base_branch: "main")
  end

  it "is ready to queue into straight away" do
    call(name: "lists", owner: "Gembani")

    response = McpTools::QueueRunTool.call(task: "Build the subscribe page", workspace: "lists", server_context: {})

    expect(response.error?).to be(false)
    expect(Workspace.find_by!(name: "lists").runs.sole).to have_attributes(base_branch: "main", status: "queued")
  end

  it "uses the default GitHub owner setting when no owner is given, else the gh user" do
    Setting["default_github_owner"] = "Gembani"
    expect(call(name: "lists").structured_content).to include(githubRepository: "Gembani/lists")

    Setting["default_github_owner"] = nil
    expect(call(name: "other").structured_content).to include(githubRepository: "operator/other")
  end

  it "clones a project only on GitHub, registering it on its own default branch" do
    gh.seed("Gembani/archive", branch: "trunk")

    response = call(name: "archive", owner: "Gembani")

    expect(response.structured_content).to include(name: "archive", defaultBaseBranch: "trunk", steps: %w[clone])
    expect(git(File.join(source, "archive"), "log", "--format=%s")).to eq("seed")
  end

  it "takes an existing local repository by path, naming it after its directory, and puts it on GitHub" do
    path = File.join(tmp, "elsewhere", "notes")
    FileUtils.mkdir_p(path)
    git(path, "init", "--quiet", "--initial-branch=main")
    File.write(File.join(path, "notes.md"), "hi\n")
    git(path, "add", ".")
    git(path, "commit", "--quiet", "-m", "notes")

    response = call(path:, owner: "Gembani")

    expect(response.structured_content).to include(name: "notes", repositoryPath: path, defaultBaseBranch: "main",
                                                   steps: %w[create_github_repository push_branch], originUrl: gh.remote("Gembani/notes"))
  end

  it "asks for a projects directory when none is set and no path is given, suggesting where the workspaces are" do
    Setting["projects_dir"] = nil

    response = call(name: "lists")

    expect(problem_codes(response)).to eq(%w[projects_dir_unset])
    expect(response.structured_content[:message]).to include("update_settings projectsDir", "most workspaces are in #{source}")
    expect(gh.calls).to be_empty
  end

  it "does nothing, on disk or on GitHub, when the workspace or repository is taken, and says so with everything else" do
    FileUtils.mkdir_p(File.join(source, "zendin-back"))
    gh.seed("Gembani/zendin-back")

    response = nil
    expect { response = call(name: "zendin-back", owner: "Gembani", visibility: "secret") }.not_to change(Workspace, :count)

    expect(response.error?).to be(true)
    expect(problem_codes(response)).to eq(%w[name_taken repository_taken visibility_invalid github_repository_exists])
    expect(response.structured_content[:message]).to start_with("Nothing was done. Fix these and call create_workspace again:")
    expect(gh_writes).to be_empty
  end

  it "does nothing when gh is not logged in" do
    gh.update("authenticated" => false)

    response = call(name: "lists", owner: "Gembani")

    expect(problem_codes(response)).to eq(%w[gh_unauthenticated])
    expect(File.exist?(File.join(source, "lists"))).to be(false)
    expect(Workspace.count).to eq(1)
  end

  it "leaves nothing behind when GitHub refuses the repository after the local one was made" do
    gh.update("create" => "fail")

    response = call(name: "lists", owner: "Gembani")

    expect(response.structured_content).to include(error: "workspace_not_created",
                                                   remaining: { localRepository: nil, githubRepository: nil })
    expect(response.structured_content[:message]).to include("was removed again")
    expect(File.exist?(File.join(source, "lists"))).to be(false)
    expect(Workspace.count).to eq(1)
  end

  it "reports what exists when the push fails, and a second call finishes and registers it" do
    gh.update("create" => "push_fail")

    response = call(name: "lists", owner: "Gembani")

    path = File.join(source, "lists")
    expect(response.structured_content).to include(error: "workspace_not_created",
                                                   remaining: { localRepository: path, githubRepository: "Gembani/lists" },
                                                   steps: %w[create_directory git_init first_commit create_github_repository])
    expect(response.structured_content[:message]).to include("call create_workspace again", "git -C #{path} push -u origin main")
    expect(Workspace.count).to eq(1)

    FileUtils.rm(File.join(gh.remote("Gembani/lists"), "hooks", "pre-receive"))
    expect(call(name: "lists", owner: "Gembani").structured_content).to include(name: "lists", steps: %w[push_branch])
  end

  it "says to register by hand when the project is ready but cannot be registered" do
    allow(Orchestrator::WorkspaceRegistration).to receive(:register).and_wrap_original do |original, **arguments|
      workspace, result = original.call(**arguments)
      workspace.destroy!
      [ nil, result.merge("problems" => [ { "code" => "name_taken", "message" => "A workspace named \"lists\" already exists." } ]) ]
    end

    response = call(name: "lists", owner: "Gembani")

    expect(response.structured_content).to include(error: "workspace_not_registered")
    expect(response.structured_content[:message]).to include("is ready (create directory, git init", "call register_workspace")
  end
end
