require "rails_helper"

RSpec.describe Orchestrator::GitHubUrl do
  it "parses a pull request URL into its repository and number" do
    repository, number = described_class.repository_and_number("https://github.com/example/repo/pull/42")

    assert_equal "example/repo", repository
    assert_equal "42", number
  end

  it "parses an issue URL into its repository and number" do
    repository, number = described_class.repository_and_number("https://github.com/example/repo/issues/7")

    assert_equal "example/repo", repository
    assert_equal "7", number
  end

  it "rejects a URL that is neither a pull request nor an issue" do
    assert_raises(ArgumentError) { described_class.repository_and_number("https://github.com/example/repo/commits/main") }
  end

  it "rejects a malformed URL" do
    assert_raises(ArgumentError) { described_class.repository_and_number("not a url") }
  end
end
