require "uri"

module Orchestrator
  # Shared by RunPublication and PullRequestResume, both of which need to
  # turn a GitHub issue or pull request URL into the repo/number pair `gh
  # api` needs -- GitHub treats issues and PRs as the same underlying object
  # for comments (repos/:owner/:repo/issues/:number/comments answers both),
  # so one parser covers both surfaces.
  module GitHubUrl
    module_function

    def repository_and_number(url)
      uri = URI.parse(url)
      parts = uri.path.split("/").reject(&:blank?)
      raise ArgumentError, "Invalid GitHub issue/PR URL: #{url}" unless parts.length >= 4 && %w[pull issues].include?(parts[-2])

      [ parts.first(2).join("/"), parts.last ]
    rescue URI::InvalidURIError
      raise ArgumentError, "Invalid GitHub issue/PR URL: #{url}"
    end
  end
end
