## Problem

<!-- What is wrong or missing, and why it matters. Link related issues. -->

## Approach

<!-- How this change solves it, and anything you considered and rejected. -->

## Schema and job-queue impact

<!-- Migrations, changes to config/queue.yml or config/recurring.yml, new or changed jobs. Write "None" if there are none. -->

- [ ] Needs a running instance restarted (`bin/service restart`) to take effect: queue.yml, recurring.yml, credentials, `bin/production`/`bin/service`, or an initializer

## Verification

<!-- How you verified it: which test layers you added or ran, and any manual steps (for example in bin/sandbox). Include screenshots for UI changes. -->

- [ ] `bin/verify` passes
- [ ] Added or updated specs at the right layer (unit/service/job, lifecycle for run or session state, system for UI)
- [ ] Updated docs and the "Unreleased" section of CHANGELOG.md, if user-visible
