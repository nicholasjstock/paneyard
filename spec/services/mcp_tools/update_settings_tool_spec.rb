require "rails_helper"

RSpec.describe McpTools::UpdateSettingsTool do
  let(:tmp) { File.realpath(Dir.mktmpdir("settings")) }

  after { FileUtils.remove_entry(tmp) if File.exist?(tmp) }

  def call(**arguments)
    described_class.call(server_context: {}, **arguments)
  end

  around do |example|
    original = ENV.delete(RegisteredRunner::PROJECTS_DIR_ENV_VAR)
    example.run
  ensure
    original ? ENV[RegisteredRunner::PROJECTS_DIR_ENV_VAR] = original : ENV.delete(RegisteredRunner::PROJECTS_DIR_ENV_VAR)
  end

  it "starts with the default projects directory and no owner" do
    expect(McpTools::GetSettingsTool.call(server_context: {}).structured_content)
      .to eq(projectsDir: "~/Source", projectsDirSource: "default", defaultGithubOwner: nil)
  end

  it "saves an existing directory, expanded, as the local runner's, and the owner, changing only what is passed" do
    response = call(projectsDir: "#{tmp}/", defaultGithubOwner: "Gembani")

    expect(response.error?).to be(false)
    expect(response.structured_content).to eq(projectsDir: tmp, projectsDirSource: "setting", defaultGithubOwner: "Gembani")
    expect(RegisteredRunner.local.reload.projects_dir).to eq(tmp)

    call(defaultGithubOwner: "")
    expect(Setting.to_h).to eq("default_github_owner" => nil)
    expect(Setting.count).to eq(0)
    expect(RegisteredRunner.local.reload.clone_projects_dir).to eq(tmp)

    call(projectsDir: "")
    expect(RegisteredRunner.local.reload.clone_projects_dir).to eq("~/Source")
  end

  it "saves nothing when anything is wrong, and says how to fix it" do
    RegisteredRunner.local.update!(projects_dir: tmp)

    response = call(projectsDir: File.join(tmp, "missing"), defaultGithubOwner: "not an owner")

    expect(response.error?).to be(true)
    expect(response.structured_content[:problems].map { |problem| problem[:code] }).to eq(%w[projects_dir_missing owner_invalid])
    expect(response.structured_content[:message]).to include("mkdir -p #{File.join(tmp, 'missing')}")
    expect(RegisteredRunner.local.reload.projects_dir).to eq(tmp)
    expect(Setting.to_h).to eq("default_github_owner" => nil)
  end

  it "shows a projects directory PANEYARD_PROJECTS_DIR sets, and will not change it" do
    ENV[RegisteredRunner::PROJECTS_DIR_ENV_VAR] = "/srv/projects"

    expect(McpTools::GetSettingsTool.call(server_context: {}).structured_content)
      .to include(projectsDir: "/srv/projects", projectsDirSource: "env")
    response = call(projectsDir: tmp)
    expect(response.structured_content[:problems].map { |problem| problem[:code] }).to eq(%w[projects_dir_from_env])
    expect(RegisteredRunner.local.reload.projects_dir).to be_nil
  end

  it "refuses a relative directory" do
    expect(call(projectsDir: "Source").structured_content[:problems].map { |problem| problem[:code] }).to eq(%w[path_not_absolute])
  end
end
