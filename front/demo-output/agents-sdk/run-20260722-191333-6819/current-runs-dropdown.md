# Current runs dropdown

Implemented the shared workspace UI control for active runs.

## Changes

- Added `ApplicationController#current_runs`, returning non-terminal runs (`launching`, `running`, `stopping`) across all workspaces, newest first.
- Added an accessible `#current-runs-dropdown` select to the application top navigation.
- Each option displays the workspace name and run identifier and points to `workspace_run_path(run.workspace, run)`.
- Selecting an option navigates with the browser to that canonical workspace-scoped run URL.
- Added styling and a screen-reader-only label.
- Added a JavaScript system spec covering:
  - both current runs appearing in the dropdown;
  - selecting a run from another workspace navigating to that run's workspace URL.

## Verification

- `bundle exec rspec spec/system/workspaces_spec.rb:4` — passed (1 example, 0 failures).
- `git diff --check` — passed.
- `bin/rubocop app/controllers/application_controller.rb spec/system/workspaces_spec.rb` and `bin/rubocop --no-server ...` could not run because the RuboCop server attempts to create its cache under `/Users/stockn/.cache/rubocop_cache`, which is outside the writable sandbox; it exits with `Operation not permitted` before linting.
- The full `spec/system/workspaces_spec.rb` run also showed unrelated failures in existing workspace creation/edit examples (Capybara could not find the Root path / Protected path patterns fields under the current system-test environment). The new dropdown example passes independently.

## Files changed

- `app/controllers/application_controller.rb`
- `app/views/layouts/application.html.erb`
- `app/assets/stylesheets/application.css`
- `spec/system/workspaces_spec.rb`
