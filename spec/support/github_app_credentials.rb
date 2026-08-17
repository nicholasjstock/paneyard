# config/credentials.yml.enc is one shared file across every Rails
# environment -- whatever github_app credentials happen to be configured
# there for real (production) use are otherwise visible to every spec run
# too, on whichever machine has them set. Specs that assume the App is
# unconfigured (the ENV-only "when GitHub App ID is missing" style
# contexts throughout github_app_auth_spec.rb, plus run_publication_spec.rb
# and worker_spawner_spec.rb exercising the pre-GitHubAppAuth ambient-gh
# fallback against fake tmpdir "repos") broke exactly this way the first
# time real credentials were added locally. Force the credentials-backed
# fallback to nil by default in every spec; ENV["GITHUB_APP_ID"] /
# ENV["GITHUB_APP_PRIVATE_KEY"] still take precedence in the real code
# (see GitHubAppAuth#load_app_id/#load_private_key), so specs that want to
# simulate a configured App by setting those env vars are unaffected.
RSpec.configure do |config|
  config.before do
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig).with(:github_app, :id).and_return(nil)
    allow(Rails.application.credentials).to receive(:dig).with(:github_app, :private_key).and_return(nil)
  end
end
