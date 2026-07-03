#!/usr/bin/env npx tsx
/**
 * Run a single orchestrator turn for a new run.
 *
 * This script:
 * 1. Initializes the workflow bus
 * 2. Calls the orchestrator planning logic
 * 3. Publishes spawn requests
 * 4. Saves the orchestrator state
 */

import * as fs from 'fs'
import * as path from 'path'
import { fileURLToPath } from 'url'

import { createWorkflowBus } from './workflow-bus'
import {
  buildWorkflowContext,
  planWorkflowIteration,
  publishPlannerJobs,
  writeOrchestratorState,
  appendOrchestratorTickHistory,
  type OrchestratorDecisionState
} from './workflow-mcp'

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

const PKG_ROOT = path.resolve(__dirname, '..')
const ROOT_DIR = process.env.WORKFLOW_TARGET_ROOT ? path.resolve(process.env.WORKFLOW_TARGET_ROOT) : PKG_ROOT
const FRONT_DIR = path.resolve(ROOT_DIR, 'front')
const OUTPUT_DIR = process.env.WORKFLOW_STATE_DIR
  ? path.resolve(process.env.WORKFLOW_STATE_DIR)
  : path.resolve(FRONT_DIR, 'demo-output', 'agents-sdk')
const BUS_PATH = path.join(OUTPUT_DIR, 'workflow-bus.json')

async function main(): Promise<number> {
  // Parse arguments
  const args = process.argv.slice(2)
  let runId = ''
  let task = ''
  let scenario: 'admin' | 'phone' | 'both' = 'both'
  let frontendUrl = 'http://localhost:5174'

  for (const arg of args) {
    const [flag, value] = arg.split('=', 2)
    switch (flag) {
      case '--run-id':
        runId = value
        break
      case '--task':
        task = value
        break
      case '--scenario':
        if (value === 'admin' || value === 'phone' || value === 'both') {
          scenario = value
        }
        break
      case '--frontend-url':
        frontendUrl = value
        break
    }
  }

  if (!runId) {
    process.stderr.write('Error: --run-id is required\n')
    return 1
  }

  if (!task) {
    process.stderr.write('Error: --task is required\n')
    return 1
  }

  process.stdout.write(`[STATUS] Initializing orchestrator turn for run ${runId}\n`)
  process.stdout.write(`  Task: ${task}\n`)
  process.stdout.write(`  Scenario: ${scenario}\n`)
  process.stdout.write(`  Frontend URL: ${frontendUrl}\n`)
  process.stdout.write(`  Bus path: ${BUS_PATH}\n`)

  // Create workflow context and bus
  const context = buildWorkflowContext({
    rootDir: ROOT_DIR,
    frontDir: FRONT_DIR,
    outputDir: OUTPUT_DIR,
  })
  const bus = createWorkflowBus({ storagePath: BUS_PATH })

  // Publish initial run status
  process.stdout.write(`[STATUS] Publishing initial run status\n`)
  bus.publishRunStatus({
    runId,
    phase: 'starting',
    owner: 'orchestrator',
    summary: `Starting orchestrator phase for ${scenario} scenario on ${frontendUrl}; beginning demo recording workflow.`,
  })

  // Call planning logic
  process.stdout.write(`[STATUS] Calling planning logic\n`)
  const plan = planWorkflowIteration({
    task,
    scenario,
    frontendUrl,
    verifierFinding: undefined,
    stallFinding: undefined,
  })

  process.stdout.write(`[STATUS] Plan summary: ${plan.summary}\n`)
  process.stdout.write(`[STATUS] Plan steps: ${plan.steps.length}\n`)
  for (const step of plan.steps) {
    process.stdout.write(`  - ${step.owner}: ${step.artifact}\n`)
  }

  // Publish spawn requests via the planner job mechanism
  process.stdout.write(`[STATUS] Publishing planner jobs (spawn requests)\n`)
  const jobs = publishPlannerJobs(bus, {
    runId,
    summary: plan.summary,
    plan,
  })

  process.stdout.write(`[STATUS] Published ${jobs.length} job(s) to the workflow bus\n`)
  for (const job of jobs) {
    process.stdout.write(`  - Request: ${job.requestId.slice(0, 8)}... for ${job.step.owner}\n`)
  }

  // Create and save orchestrator state
  process.stdout.write(`[STATUS] Creating orchestrator decision state\n`)
  const nextState: OrchestratorDecisionState = {
    runId,
    phase: 'planning',
    tickCount: 1,
    lastPlanSummary: plan.summary,
    pendingSpawnKeys: jobs.map((job) => JSON.stringify([runId, job.step.owner, job.step.artifact])),
    lastStallFinding: null,
    lastUpdatedAt: new Date().toISOString(),
  }

  // Write orchestrator state to disk
  process.stdout.write(`[STATUS] Persisting orchestrator state\n`)
  writeOrchestratorState(context, nextState)
  appendOrchestratorTickHistory(context, nextState)

  // Report summary
  process.stdout.write(`\n[DONE] Orchestrator turn complete\n`)
  process.stdout.write(`\nTurn Result Summary:\n`)
  process.stdout.write(`  Spawn requests published: ${jobs.length}\n`)
  process.stdout.write(`  Workers to spawn:\n`)
  for (const step of plan.steps.slice(1)) { // Skip orchestrator itself
    process.stdout.write(`    - ${step.owner} (scope: ${step.artifact})\n`)
  }
  process.stdout.write(`  Next phase: ${nextState.phase}\n`)
  process.stdout.write(`  Tick count: ${nextState.tickCount}\n`)

  return 0
}

main()
  .then((exitCode) => {
    process.exitCode = exitCode
  })
  .catch((error) => {
    const message = error instanceof Error ? error.stack ?? error.message : String(error)
    process.stderr.write(`[FAILED] ${message}\n`)
    process.exitCode = 1
  })
