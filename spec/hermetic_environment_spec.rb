require "rails_helper"
# Specs must not depend on the machine running them. The operator's main
# checkout has config/master.key and real credentials; neither may reach a spec.
RSpec.describe "The spec environment" do
  it "never reads the real credentials, even where config/master.key could decrypt them" do
    content_path = Rails.application.credentials.content_path

    expect(content_path).not_to eq(Rails.root.join("config/credentials.yml.enc"))
    expect(content_path).not_to exist
    expect(Rails.application.credentials.config).to eq({})
  end
end
