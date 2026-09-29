# GitHub App Authentication Setup

**This is optional.** Without a GitHub App, sessions push with your own `gh auth token` or SSH key; see [GitHub access](./docs/operating.md#4-github-access) for how credentials are chosen. Use an App when you want sessions to act as a bot identity limited to specific repositories rather than as you.

Rails itself makes no GitHub calls: it does not open, update, or watch pull requests. What needs GitHub credentials is each run's session, which pushes its own `workflow/<name>` branch when you ask it to (and may run `gh` if you ask it to). When a GitHub App is configured, every session gets an installation token for the app instead of letting it act as you with your own `gh auth` identity. The token reaches exactly the repositories that installation was granted, which is why "Only select repositories" below is recommended.

## Prerequisites

- A GitHub App created under your organization or your personal account
- GitHub App installed on the target repository (or repositories)
- The app's private key in PEM format

## Creating a GitHub App

Where you create the app determines which repositories it can ever be installed on — pick based on who owns the target repos, not where you happen to be clicking from:

- **Personal account repos** (e.g. `github.com/{your-username}/{repo}`): create it at `https://github.com/settings/apps/new`.
- **Organization-owned repos**: create it at `https://github.com/organizations/{ORG}/settings/apps/new`.

An app created under one can't be installed on repos owned by the other — if your repos are split between your personal account and an org, either create one app per owner, or move the repos under a single owner first.

1. Go to the URL above for your chosen owner.
2. Click "New GitHub App"
3. Fill in the form:
   - **App name**: `Workflow Orchestrator` (or similar)
   - **Homepage URL**: any valid URL, such as this project's repository page (it is not used)
   - **Webhook URL**: Leave blank (not needed for this usage)
   - **Webhook active**: Uncheck (not needed)

4. Under "Permissions", select **Repository permissions**:
   - **Contents**: Read & write — required. This is what lets a session `git push` its branch.
   - **Pull requests**: Read & write — optional. Only needed if you want to tell a session to open or update a pull request itself with `gh pr create`; otherwise you open PRs yourself from the pushed branch.

   Nothing else is needed.

5. Under **Where can this GitHub App be installed?**:
   - Select "Only on this account" for a single-owner setup (recommended — this just restricts *who can install it*, it does not make the app public or listed anywhere; that only happens if you separately publish it to the GitHub Marketplace, a distinct opt-in step this guide doesn't cover). Select "Any account" only if you need to install the same app across multiple, unrelated owners.

6. Click "Create GitHub App"

## Generating a Private Key

1. On the app's settings page, scroll to "Private keys" section
2. Click "Generate a private key"
3. GitHub will download a `.pem` file — **save this file securely** (it's only generated once)

## Installing the App

1. On the app's settings page (`https://github.com/settings/apps` → click the app), go to the **"Install App"** tab in the left sidebar.
2. Your allowed owner (personal account or org, per how you restricted it above) is listed with an **Install** button — click it.
3. Choose repository access:
   - **"Only select repositories"**: pick the specific repos this orchestrator will run against. Recommended — the app's token can then only ever be minted for those repos.
   - **"All repositories"**: also works with no code changes, but grants the app (and thus any orchestrator process using its token) access to every current and future repo under that account/org. Functionally identical to Rails — `Orchestrator::GitHubAppAuth` resolves one installation per account/org regardless of which repos it covers — but it's a broader security scope than most setups need.
4. Click **Install**.

You'll land on `https://github.com/settings/installations/{INSTALLATION_ID}` — that's the installation ID, but see the note under `GITHUB_APP_INSTALLATION_ID` below before setting it.

To change repo access later (add/remove repos), go to `https://github.com/settings/installations` (or your org's equivalent) and click **Configure** next to the app — no need to reinstall or recreate anything.

## Configuring the Orchestrator

### Option 1: Environment variables

Set these in the environment the orchestrator starts from (the shell you run `bin/dev` or `bin/service start`/`restart` in):

```bash
export GITHUB_APP_ID=12345                    # Numeric app ID
export GITHUB_APP_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----
...
-----END RSA PRIVATE KEY-----"
export GITHUB_APP_INSTALLATION_ID=98765       # Optional -- see note below before setting this
```

**Leave `GITHUB_APP_INSTALLATION_ID` unset if the orchestrator will operate against more than one repository or owner.** When unset, `Orchestrator::GitHubAppAuth` looks up the correct installation per repository automatically from `remote.origin.url`, so one app install covers every repo it's granted access to. Setting this variable pins every token request to that one specific installation, regardless of which repo a given run actually targets — correct only if the orchestrator will only ever run against a single, fixed repo.

### Option 2: Rails credentials

Store them in the encrypted credentials file, which needs your own `config/master.key` (see the README's [Quickstart](./README.md#3-start-the-orchestrator); `config/*.key` is gitignored, so never commit it):

```bash
bin/rails credentials:edit
```

Add:

```yaml
github_app:
  id: 12345
  private_key: |
    -----BEGIN RSA PRIVATE KEY-----
    MIIEpAIBAAKCAQEA...
    ...
    -----END RSA PRIVATE KEY-----
```

Environment variables win over credentials when both are set (`config/initializers/github_app.rb`). Restart a running `bin/service` instance (`bin/service restart`) after changing either.

## Verifying the Setup

Run this Rails command to verify the app is configured:

```bash
bin/rails runner 'puts Orchestrator::GitHubAppAuth.app_configured?'
```

Should print `true`. (Add `RAILS_ENV=production` to check the environment `bin/service` runs in.)

To test token generation for a specific repository, pass its `origin` URL:

```bash
bin/rails runner '
  token = Orchestrator::GitHubAppAuth.installation_token_for { "https://github.com/OWNER/REPO.git" }
  puts "Token generated: #{token[0..8]}..."
'
```

With `RAILS_ENV=production`, the Rails cache is shared with the running instance, so a token minted in the last 55 minutes is returned without looking this repository up at all. In that case the check proves the App credentials work, not that this particular repository is covered.

## How It Works

1. When a run's session starts, `Orchestrator::RunSessionRunner.session_spec` (via `Orchestrator::GitHubAppAuth`):
   - Checks if GitHub App credentials are configured
   - Generates a JWT signed with the app's private key
   - Exchanges it for an access token for the installation that covers the run's repository (looked up from `remote.origin.url`, which it asks the run's runner for, unless `GITHUB_APP_INSTALLATION_ID` is set)
   - Caches the token for 55 minutes (tokens are valid for 1 hour), so a session may start with one that is already up to 55 minutes old
   - Hands it to the runner, whose `Orchestrator::Runner::ProcessEnv` puts it in the session's environment as `GH_TOKEN`, and appends `gh auth git-credential` as a git credential helper, so both `gh` and plain `git push` authenticate with it

2. If the GitHub App is not configured, or minting a token fails, the session gets whatever `gh auth token` returns for the user on the runner's machine instead.

The token is fixed when the session starts. A session left open for long enough will find it expired and its next push failing; close the session and start a new run, or push that branch yourself.

## Troubleshooting

### "GitHub App ID not configured"

Check that one of these is true:
- `GITHUB_APP_ID` environment variable is set
- `config/credentials.yml.enc` contains `github_app.id`
- If you use credentials, the process can decrypt them (`config/master.key` or `RAILS_MASTER_KEY` is present)

### "GitHub App not installed for repository"

Make sure:
- The app is installed on the target organization/repository
- The `GITHUB_APP_INSTALLATION_ID` environment variable (if set) is correct
- The repository's `remote.origin.url` is correctly configured

### A session's `git push` is rejected with 403

The installation lacks **Contents: Read & write** on that repository, or the repository is not among the ones the installation was granted (see "Installing the App"). If you change the app's permissions, GitHub queues a permission-update request: approve it at `https://github.com/settings/installations` (or your org's equivalent). A session only picks up the new scope with a token minted after the change, so a new session (and possibly up to 55 minutes for the cached token to expire).

### "Failed to get GitHub App token"

Check:
- The private key is valid PEM format
- The private key hasn't been revoked on GitHub
- GitHub API is accessible from the orchestrator's network
- Token generation hasn't exceeded rate limits

## Security Notes

- **Never commit private keys** to version control
- **Rotate private keys regularly** by regenerating them on GitHub
- **Restrict app permissions** to only what's needed (Contents, plus Pull requests only if sessions open PRs)
- **Monitor app usage** in GitHub audit logs for suspicious activity
- **Limit installation scope** to only target repositories/organizations

## Reference

- [GitHub App Documentation](https://docs.github.com/en/developers/apps)
- [Authenticating as a GitHub App](https://docs.github.com/en/developers/apps/building-github-apps/authenticating-with-github-apps)
- [GitHub REST API - Tokens](https://docs.github.com/en/rest/guides/getting-started-with-the-rest-api?apiVersion=2022-11-28#authentication)
