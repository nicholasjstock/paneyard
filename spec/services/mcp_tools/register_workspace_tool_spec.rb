require "rails_helper"
require "open3"

RSpec.describe McpTools::RegisterWorkspaceTool do
  let(:tmp) { Dir.mktmpdir("register-workspace") }

  after { FileUtils.remove_entry(tmp) if File.exist?(tmp) }

  def git(dir, *args)
    _output, error, status = Open3.capture3("git", "-C", dir.to_s, *args)
    raise "git #{args.join(' ')} failed: #{error}" unless status.success?
  end

  # A real checkout at <root>/main, laid out as a workspace needs it unless
  # told otherwise.
  def layout(name, branch: "main", origin: true)
    root = File.join(tmp, name)
    main = File.join(root, "main")
    FileUtils.mkdir_p(main)
    git(main, "init", "--initial-branch=#{branch}")
    git(main, "config", "user.email", "register@example.test")
    git(main, "config", "user.name", "Register")
    File.write(File.join(main, "README.md"), "hi\n")
    git(main, "add", ".")
    git(main, "commit", "-m", "initial")
    git(main, "remote", "add", "origin", "https://example.test/#{name}.git") if origin
    root
  end

  def call(name, root)
    described_class.call(name:, rootPath: root, server_context: {})
  end

  it "registers a correctly laid-out root and answers as list_workspaces does" do
    root = layout("demo")

    response = nil
    expect { response = call("demo", root) }.to change(Workspace, :count).by(1)

    expect(response.error?).to be(false)
    expect(response.structured_content).to include(
      name: "demo", rootPath: root, sourceRoot: File.join(root, "main"),
      originUrl: "https://example.test/demo.git", activeRuns: 0
    )
    expect(Workspace.find_by!(name: "demo").root_path).to eq(root)
  end

  it "registers the workspace above when given the main checkout itself" do
    root = layout("demo")

    response = call("demo", File.join(root, "main"))

    expect(response.error?).to be(false)
    expect(response.structured_content).to include(rootPath: root, sourceRoot: File.join(root, "main"))
    expect(Workspace.find_by!(name: "demo").root_path).to eq(root)
  end

  it "counts the main checkout as the root already registered above it" do
    root = layout("demo")
    Workspace.create!(name: "first", root_path: root)

    response = call("second", File.join(root, "main"))

    expect(response.structured_content[:problems].map { |p| p[:code] }).to eq(%w[root_path_taken])
  end

  it "creates nothing for a plain clone with no main/ child" do
    root = File.join(layout("demo"), "main")
    plain = File.join(tmp, "plain")
    FileUtils.mv(root, plain)

    response = call("plain", plain)

    expect(response.structured_content[:problems].map { |p| p[:code] }).to eq(%w[root_path_is_repository])
    expect(Workspace.count).to eq(0)
  end

  it "returns every problem at once: a taken name, a master checkout, and no origin" do
    create_workspace(prefix: "taken").update!(name: "taken")
    root = layout("demo", branch: "master", origin: false)

    response = call("taken", root)

    expect(response.error?).to be(true)
    expect(response.structured_content[:problems].map { |p| p[:code] }).to eq(%w[name_taken source_not_on_main no_origin])
    expect(response.structured_content[:message]).to start_with("Nothing was registered.").and include("1. ", "2. ", "3. ")
    expect(Workspace.where(name: "taken").count).to eq(1)
  end

  it "refuses a root another workspace already has, however it is spelled" do
    root = layout("demo")
    Workspace.create!(name: "first", root_path: root)

    response = call("second", "#{root}/")

    expect(response.structured_content[:problems].map { |p| p[:code] }).to eq(%w[root_path_taken])
    expect(response.structured_content[:message]).to include('Workspace "first" is already registered')
    expect(Workspace.find_by(name: "second")).to be_nil
  end
end
