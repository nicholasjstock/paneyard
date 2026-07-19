# Workflow Orchestrator

Rails owns run state, bounded planning decisions, worker processes, and recovery. Start work from a workspace; runs and their workers, questions, events, artifacts, and operator chat remain scoped to it.

## Local setup

```sh
bin/setup --skip-server
bin/dev
```

`bin/dev` starts Puma and Solid Queue together. Before starting either process it checks the bundle, pending migrations, and the configured `PORT` (default `3000`). It exits with a recovery command instead of starting a partially functional orchestrator.

If startup reports incomplete dependencies or an unprepared database, run:

```sh
bin/setup --skip-server
```

If the port is occupied, stop the owning service or choose an explicit orchestrator port:

```sh
PORT=3300 WORKFLOW_RAILS_URL=http://127.0.0.1:3300 bin/dev
```

The health endpoint returns `{"status":"ok","service":"workflow-orchestrator"}` and the `X-Workflow-Service: workflow-orchestrator` header, so it cannot be mistaken for a target Rails application merely because both expose `/up`.

## Verification

```sh
bundle exec rspec
bin/rubocop
git diff --check
```

`bin/ci` additionally runs dependency, importmap, and Brakeman audits.

## Worker execution policy

Before spawning a worker, Rails verifies only that the target directory and selected agent launcher exist. The workspace does not need orchestrator-specific command configuration.

Workers inspect each repository and run its native commands through Codex or Claude. Safeguards are applied at that launcher boundary: artifact-only workers receive read-only repository access, while implementation workers receive write access only to the planner-authorized exact files. Commands run in the foreground so child processes remain in the worker's process group and inherit the same filesystem policy.

Rails never executes worker-supplied shell commands outside that sandbox and never infers a workspace's language, package manager, dependency layout, ports, or health endpoints.
