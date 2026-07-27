# GitHub App Authentication Setup

This orchestrator uses GitHub App authentication for all GitHub operations (PR creation, comments, releases, etc.) instead of relying on user credentials or personal access tokens.

## Prerequisites

- A GitHub App created in your target repository's organization
- GitHub App installed on the target repository
- The app's private key in PEM format

## Creating a GitHub App

1. Go to your organization's settings: `https://github.com/organizations/{ORG}/settings/apps`
2. Click "New GitHub App"
3. Fill in the form:
   - **App name**: `Workflow Orchestrator` (or similar)
   - **Homepage URL**: `https://your-orchestrator-url.com` (or any valid URL)
   - **Webhook URL**: Leave blank (not needed for this usage)
   - **Webhook active**: Uncheck (not needed)

4. Under "Permissions", select **Repository permissions**:
   - **Pull requests**: Read & write
   - **Contents**: Read & write (only needed if committing)
   - **Releases**: Read & write

5. Under **Where can this GitHub App be installed?**:
   - Select "Only on this account" (or "Any account" if you want multi-org support)

6. Click "Create GitHub App"

## Generating a Private Key

1. On the app's settings page, scroll to "Private keys" section
2. Click "Generate a private key"
3. GitHub will download a `.pem` file — **save this file securely** (it's only generated once)

## Installing the App

1. On the app's settings page, go to "Install App" tab
2. Click "Install" next to your target repository/organization
3. Note the **installation ID** from the URL: `https://github.com/settings/installations/{INSTALLATION_ID}`

## Configuring the Orchestrator

### Option 1: Environment Variables (Recommended for CI/CD)

Set these environment variables before starting the orchestrator:

```bash
export GITHUB_APP_ID=12345                    # Numeric app ID
export GITHUB_APP_PRIVATE_KEY="-----BEGIN RSA PRIVATE KEY-----
...
-----END RSA PRIVATE KEY-----"
export GITHUB_APP_INSTALLATION_ID=98765       # Optional, for faster token generation
```

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
