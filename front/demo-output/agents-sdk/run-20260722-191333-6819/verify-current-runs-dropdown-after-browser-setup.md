# Verification: current-runs dropdown after browser setup

## Objective

Run exactly `bundle exec rspec spec/system/workspaces_spec.rb:4` from a writable checkout with writable Rails runtime directories and Selenium cache, using a launchable Chrome/Chromium, and capture positive browser evidence for the current-runs dropdown and workspace-scoped navigation.

## Environment preparation

The source-protected checkout contains the candidate implementation and is not writable for Rails runtime state. I created an isolated temporary copy under `/private/var/folders/m8/klqqpg3x035gd5jnd6vby_p80000gn/T/current-runs-dropdown-rerun.XXXXXX/repo` and created writable `storage/`, `log/`, `tmp/cache/`, and `tmp/capybara/` directories. Selenium cache variables were redirected to a writable temporary cache, and `/Applications/Google Chrome.app/Contents/MacOS` was added to PATH.

## Required spec result

Command, run from the isolated copy:

`bundle exec rspec spec/system/workspaces_spec.rb:4`

Result:

- Rails initialized the writable test database successfully.
- 1 example executed, 1 failure.
- Failure occurred at `spec/system/workspaces_spec.rb:16`, the first browser action: `visit workspace_run_path(first_workspace, first_run)`.
- Error: `Selenium::WebDriver::Error::SessionNotCreatedError: session not created: Chrome instance exited`.
- RSpec summary: `1 example, 1 failure`.
- None of the dropdown option assertions, `select`, canonical workspace-scoped URL assertion, or selected-run task assertion executed.

## Browser launch evidence

Detected browser:

`/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`

A bounded direct smoke test using the same relevant flags:

`--headless=new --no-sandbox --disable-dev-shm-usage`

with an isolated writable `--user-data-dir` exited with code `134` and produced no DOM output.

## Outcome

Blocked. Positive browser evidence was not obtained because Chrome exits during session creation. The acceptance criterion `current-runs-dropdown-switches-workspaces` remains pending; no acceptance verification was submitted as verified.

## Files and commands

Files changed: none.

Commands run:

- Read-only checkout/spec/driver and browser checks.
- Exact `bundle exec rspec spec/system/workspaces_spec.rb:4` in the isolated writable copy.
- Direct bounded Chrome headless smoke launch.

Suggested downstream scope: environment/browser infrastructure should provide a launchable Chrome/Chromium session compatible with Selenium WebDriver 4.45.0, then rerun the exact spec.