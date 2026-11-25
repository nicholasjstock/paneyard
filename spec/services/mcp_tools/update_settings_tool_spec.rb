require "rails_helper"

RSpec.describe McpTools::UpdateSettingsTool do
  let(:tmp) { File.realpath(Dir.mktmpdir("settings")) }

  after { FileUtils.remove_entry(tmp) if File.exist?(tmp) }

  def call(**arguments)
    described_class.call(server_context: {}, **arguments)
  end

  it "starts with nothing set" do
    expect(McpTools::GetSettingsTool.call(server_context: {}).structured_content)
      .to eq(projectsDir: nil, defaultGithubOwner: nil)
  end

  it "saves an existing directory, expanded, and the owner, changing only what is passed" do
    response = call(projectsDir: "#{tmp}/", defaultGithubOwner: "Gembani")

    expect(response.error?).to be(false)
    expect(response.structured_content).to eq(projectsDir: tmp, defaultGithubOwner: "Gembani")

    call(defaultGithubOwner: "")
    expect(Setting.to_h).to eq("projects_dir" => tmp, "default_github_owner" => nil)
    expect(Setting.count).to eq(1)
  end

  it "saves nothing when anything is wrong, and says how to fix it" do
    Setting["projects_dir"] = tmp

    response = call(projectsDir: File.join(tmp, "missing"), defaultGithubOwner: "not an owner")

    expect(response.error?).to be(true)
    expect(response.structured_content[:problems].map { |problem| problem[:code] }).to eq(%w[projects_dir_missing owner_invalid])
    expect(response.structured_content[:message]).to include("mkdir -p #{File.join(tmp, 'missing')}")
    expect(Setting.to_h).to eq("projects_dir" => tmp, "default_github_owner" => nil)
  end

  it "refuses a relative directory" do
    expect(call(projectsDir: "Source").structured_content[:problems].map { |problem| problem[:code] }).to eq(%w[path_not_absolute])
  end
end
