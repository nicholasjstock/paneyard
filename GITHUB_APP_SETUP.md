# GitHub App Authentication Setup

This orchestrator uses GitHub App authentication for all GitHub operations (PR creation, comments, releases, etc.) instead of relying on user credentials or personal access tokens.

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
   - **Homepage URL**: `https://your-orchestrator-url.com` (or any valid URL)
   - **Webhook URL**: Leave blank (not needed for this usage)
   - **Webhook active**: Uncheck (not needed)

4. Under "Permissions", select **Repository permissions**:
   - **Pull requests**: Read & write
   - **Contents**: Read & write — this also covers release management (`gh release create`/`delete`, used to attach/clean up review evidence); GitHub Apps have no separate "Releases" permission, it's folded into Contents.
   - **Issues**: Read & write — required for the operator plan-approval gate (`Orchestrator::RunPublication`), which opens a GitHub issue per run to carry the first-step approval conversation and closes it once the run's PR is up. Without this, `gh issue create` fails with `GraphQL: Resource not accessible by integration (createIssue)` and the run sits retrying `PublishUserQuestionJob` indefinitely instead of surfacing the plan for approval.

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

### Option 1: Environment Variables (Recommended for CI/CD)

Set these environment variables before starting the orchestrator:

```bash
export GITHUB_APP_ID=12345                    # Numeric app ID
export GITHUB_APP_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----
...
-----END RSA PRIVATE KEY-----"
export GITHUB_APP_INSTALLATION_ID=98765       # Optional -- see note below before setting this
```

**Leave `GITHUB_APP_INSTALLATION_ID` unset if the orchestrator will operate against more than one repository or owner.** When unset, `Orchestrator::GitHubAppAuth` looks up the correct installation per repository automatically from `remote.origin.url`, so one app install covers every repo it's granted access to. Setting this variable pins every token request to that one specific installation, regardless of which repo a given run actually targets — correct only if the orchestrator will only ever run against a single, fixed repo.

### Option 2: Rails Credentials (Recommended for Development)

Store credentials in `config/credentials.yml.enc`:

```bash
rails credentials:edit
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

Then set the master key:

```bash
# Generate and save to config/master.key (add to .gitignore)
rails credentials:edit
```

### Option 3: Deployment Configuration

For production deployments using Kamal or other orchestration, add secrets to your deployment config:

```yaml
# config/deploy.yml
env:
  secret:
    - RAILS_MASTER_KEY
    - GITHUB_APP_ID
    - GITHUB_APP_PRIVATE_KEY
    - GITHUB_APP_INSTALLATION_ID
```

Then set the secrets:

```bash
kamal secrets set GITHUB_APP_ID=12345 GITHUB_APP_PRIVATE_KEY="..." GITHUB_APP_INSTALLATION_ID=98765
```

### Option 4: GitHub Actions CI/CD Secrets

To use GitHub App authentication in GitHub Actions workflows (e.g., for running tests or deploying):

1. Go to your repository: `https://github.com/{OWNER}/{REPO}/settings/secrets/actions`
2. Click "New repository secret"
3. Add the following secrets:

   - Name: `GITHUB_APP_ID`
     Value: Your app's ID (numeric value)

   - Name: `GITHUB_APP_PRIVATE_KEY`
     Value: Your private key (full PEM content, including BEGIN/END lines)

   - Name: `GITHUB_APP_INSTALLATION_ID` (optional)
     Value: Your installation ID (numeric value, for faster token generation)

4. In your workflow (`.github/workflows/ci.yml`), reference these secrets:

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    env:
      GITHUB_APP_ID: ${{ secrets.GITHUB_APP_ID }}
      GITHUB_APP_PRIVATE_KEY: ${{ secrets.GITHUB_APP_PRIVATE_KEY }}
      GITHUB_APP_INSTALLATION_ID: ${{ secrets.GITHUB_APP_INSTALLATION_ID }}
    steps:
      - name: Checkout code
        uses: actions/checkout@v6
      
      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      
      - name: Run tests
        run: bundle exec rspec
```

## Verifying the Setup

Run this Rails command to verify the app is configured:

```bash
rails runner 'puts Orchestrator::GitHubAppAuth.app_configured?'
```

Should return `true`.

To test token generation for a specific repository:

```bash
rails runner '
  token = Orchestrator::GitHubAppAuth.installation_token_for(workspace_root: "/path/to/repo")
  puts "Token generated: #{token[0..20]}..."
'
```

## How It Works

1. When the orchestrator needs to make a GitHub API call (via `gh` CLI or direct API), it:
   - Checks if GitHub App credentials are configured
   - Generates a JWT token signed with the app's private key
   - Exchanges the JWT for an installation access token
   - Caches the token for 55 minutes (tokens are valid for 1 hour)
   - Passes the token to all `gh` commands via `GH_TOKEN` environment variable

2. The `gh` CLI automatically uses `GH_TOKEN` when present, so no additional configuration is needed in the CLI itself.

3. If GitHub App is not configured, the orchestrator falls back to using whatever credentials the `gh` CLI has already configured (local user auth).

## Troubleshooting

### "GitHub App ID not configured"

Check that one of these is true:
- `GITHUB_APP_ID` environment variable is set
- `config/credentials.yml.enc` contains `github_app.id`
- Rails is in production environment and has the secret configured

### "GitHub App not installed for repository"

Make sure:
- The app is installed on the target organization/repository
- The `GITHUB_APP_INSTALLATION_ID` environment variable (if set) is correct
- The repository's `remote.origin.url` is correctly configured

### "Resource not accessible by integration (createIssue)"

The installation is missing the **Issues: Read & write** permission (see step 4 above). This can happen even to an already-installed app if it predates this permission being added:

1. On the app's settings page, under **Permissions & events**, set **Issues** to **Read & write** and save.
2. GitHub will queue a permission-update request rather than applying it immediately. Go to `https://github.com/settings/installations` (or your org's equivalent), find this app's installation, and approve the pending permission request.
3. No orchestrator restart is needed — `Orchestrator::GitHubAppAuth` mints a fresh installation token per request, so the next retry of `PublishUserQuestionJob` picks up the new scope automatically.

### "Failed to get GitHub App token"

Check:
- The private key is valid PEM format
- The private key hasn't been revoked on GitHub
- GitHub API is accessible from the orchestrator's network
- Token generation hasn't exceeded rate limits

## Security Notes

- **Never commit private keys** to version control
- **Rotate private keys regularly** by regenerating them on GitHub
- **Use environment variables** (not credentials files) in CI/CD pipelines
- **Restrict app permissions** to only what's needed (PR, contents, releases)
- **Monitor app usage** in GitHub audit logs for suspicious activity
- **Limit installation scope** to only target repositories/organizations

## Reference

- [GitHub App Documentation](https://docs.github.com/en/developers/apps)
- [Authenticating as a GitHub App](https://docs.github.com/en/developers/apps/building-github-apps/authenticating-with-github-apps)
- [GitHub REST API - Tokens](https://docs.github.com/en/rest/guides/getting-started-with-the-rest-api?apiVersion=2022-11-28#authentication)
