# Infrastructure

Treat infrastructure work as an evidence-driven reliability investigation. Preserve user work, limit blast radius, and leave the system measurably healthier than it was.

## Investigation

1. State the affected operation, expected outcome, and observed failure. Identify the request, job, worker, process, service, or deployment involved.
2. Collect the smallest useful evidence set before changing anything: current state, recent logs with timestamps, process/service ownership, configuration, and the last successful or failed transition.
3. Separate liveness from progress. A live process may be blocked; an exited process may have completed; a queue may be healthy while a consumer is not.
4. Trace the boundary where work stops moving: caller to queue, queue to worker, parent to child process, service to service, or producer to log stream. Check both sides of that boundary.
5. Form a falsifiable hypothesis. Prefer a cheap, read-only check or a narrowly scoped reproduction before a fix.

## Intervention

- Make the smallest reversible change that tests the hypothesis. Preserve logs, artifacts, and identifiers needed for comparison.
- Confirm process ownership and scope before stopping or restarting anything. Do not kill broad process groups, recycle shared services, clear queues, delete volumes, prune containers, or remove caches without explicit authorization and a documented recovery path.
- Do not treat retries, polling, or longer timeouts as a fix unless evidence shows transient failure and bounded retry behavior is correct.
- Keep diagnostic payloads bounded. Request recent, relevant records and log tails first; paginate or filter before loading histories, events, or artifacts wholesale.
- For log visibility issues, verify every link in the delivery path: producer flushes output, collector observes new bytes, transport is connected, UI subscription is active, and the rendered view updates. Use timestamps to measure latency rather than guessing.

## Verification

1. Verify the original failure path, not only a command that exits successfully.
2. Check success, failure, cancellation, and restart behavior where applicable. Confirm child processes do not outlive their owner unintentionally and intentional background work has explicit ownership.
3. Add or update the nearest practical regression coverage, health check, or diagnostic assertion.
4. Report the root cause or the remaining uncertainty, files/configuration changed, commands run, evidence of recovery, and any safe follow-up work.

## Escalation

If evidence is insufficient, report the exact missing signal and add targeted observability when safe. If the next action risks data loss, interrupts shared users, changes credentials, or modifies production state, stop and request explicit approval with the proposed command and impact.
