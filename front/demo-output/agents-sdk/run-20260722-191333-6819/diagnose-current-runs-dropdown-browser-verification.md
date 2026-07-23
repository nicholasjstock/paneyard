# Diagnosis: current-runs dropdown browser verification

## Objective

Identify why the existing acceptance spec cannot reach the browser assertions, and state the concrete environment conditions required to rerun it. No application or public-contract changes were made.

## Reproduction evidence

From the target source-protected checkout:

`bundle exec rspec spec/system/workspaces_spec.rb:4`

Result:

`SQLite3::CantOpenException: unable to open database file`

Rails also emitted:

`Rails Error: Unable to access log file. Please ensure that .../log/test.log exists and is writable`

RSpec reported `0 examples, 0 failures, 1 error occurred outside of examples`. The test database is configured as `storage/test.sqlite3` in `config/database.yml`, so the checkout must permit creation/opening of `storage/` and writing `log/test.log` before the spec can reach Selenium.

The prior independent verifier reran the same spec from a sandbox-writable repository copy. In that copy, the test database initialized, but the first browser action:

`visit workspace_run_path(first_workspace, first_run)`

failed with:

`Selenium::WebDriver::Error::SessionNotCreatedError: session not created: Chrome instance exited`

RSpec reported `1 example, 1 failure`; none of the dropdown or workspace-navigation assertions ran.

The configured driver in `spec/support/system_specs.rb` is Selenium Chrome with `--headless=new`, `--no-sandbox`, and `--disable-dev-shm-usage`. The current environment has no executable for any of:

- `google-chrome`
- `google-chrome-stable`
- `chromium`
- `chromium-browser`

A direct driver smoke test using Selenium WebDriver `4.45.0` reproduced the browser failure and returned `session not created: Chrome instance exited`. It also logged:

`Metadata cannot be written in cache (/Users/stockn/.cache/selenium): Operation not permitted`

The cache warning is secondary to the missing/unusable browser: Selenium reached chromedriver, but no Chrome session was created.

## Confirmed boundary

The acceptance branch stops before the first `visit` assertion because the environment cannot create a Chrome session. The UI behavior—displaying both current runs and selecting the second run to switch to its workspace—remains unverified; no browser interaction executed.

## Conditions required for a rerun

1. Run the existing spec from a writable repository checkout (or otherwise provide write access to the checkout's `storage/` and `log/test.log`) so Rails can create/open `storage/test.sqlite3` and write test logs.
2. Install a launchable Chrome or Chromium browser compatible with the Selenium-managed chromedriver, and make its executable discoverable by Selenium (the existing driver does not set a custom binary path). A standard `google-chrome`, `google-chrome-stable`, `chromium`, or `chromium-browser` executable on PATH satisfies discovery.
3. If Selenium Manager must download or refresh the driver, make `~/.cache/selenium` writable or pre-provision a compatible chromedriver. The current run logged that this cache is not writable.
4. Rerun exactly `bundle exec rspec spec/system/workspaces_spec.rb:4`; only a run that reaches and passes the option assertions, `select`, current-path assertion, and selected-run task assertion can verify the criterion.

## Files changed

None.
