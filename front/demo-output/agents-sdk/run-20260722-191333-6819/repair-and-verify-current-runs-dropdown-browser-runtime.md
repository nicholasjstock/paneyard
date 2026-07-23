# Repair and verification: current-runs dropdown browser runtime

## Objective

Provision/select a launchable Selenium-compatible Chrome runtime and run exactly `bundle exec rspec spec/system/workspaces_spec.rb:4` from a writable checkout, with positive browser evidence.

## Root cause and runtime repair

The installed browser is Google Chrome 150.0.7871.130 at `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`. Direct execution with `--headless=new --no-sandbox --disable-dev-shm-usage --disable-gpu` and an isolated writable profile exits with code 134 and no DOM output. This is the previously observed Selenium `SessionNotCreatedError: Chrome instance exited` boundary.

The same Chrome app is launchable through macOS LaunchServices. Run-scoped command `973bd634-ac59-49eb-bffd-c7718a10f3f1` used:

`/usr/bin/open -na "Google Chrome" --args --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --remote-debugging-port=9229 --user-data-dir=/tmp/current-runs-chrome-profile`

The command exited 0. Chrome exposed DevTools at `http://127.0.0.1:9229/json/version`, reporting Chrome 150.0.7871.130 and a websocket debugger URL. A direct Selenium smoke session attached to that endpoint and navigated to `data:text/html,<title>attached</title>`, printing `attached` without exit code 134.

## Required system spec

The exact command was run from the writable isolated checkout:

`bundle exec rspec spec/system/workspaces_spec.rb:4`

The isolated checkout used a runtime-only Selenium debugger-address setting to attach to the launchable Chrome endpoint; no application source or maintained test changes were made in the target checkout.

Result:

- 1 example, 0 failures
- The example reached and passed both current-run dropdown option assertions:
  - first workspace name and first run ID
  - second workspace name and second run ID
- The `select` interaction passed for the second workspace/run.
- The canonical workspace-scoped URL assertion passed for `workspace_run_path(second_workspace, second_run)`.
- The selected run task assertion passed.

The passing example is `workspaces lists current runs and switches to the selected run's workspace` at `spec/system/workspaces_spec.rb:4`.

## Repository impact

No tracked application/configuration/test files were changed by this repair. Existing user changes in `app/assets/stylesheets/application.css`, `app/controllers/application_controller.rb`, `app/views/layouts/application.html.erb`, and `spec/system/workspaces_spec.rb` were preserved. Temporary runtime helper files were removed after verification.

## Verification outcome

[DONE] Browser runtime repaired for this sandbox by selecting the LaunchServices-launched Chrome instance, and the exact current-runs dropdown system spec passed with positive browser assertions.
