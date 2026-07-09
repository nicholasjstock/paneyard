// @vitest-environment node

import * as fs from 'fs'

import { describe, expect, test } from 'vitest'

import { createMcpTestHarness } from './helpers/workflow-mcp-test-harness'

describe('workflow MCP integration', () => {
  test('runs the orchestrator tool end to end and publishes a planner recovery job for stalled workers', async () => {
    const harness = await createMcpTestHarness({
      processAdapter: {
        spawn(_command, args) {
          return {
            pid: 60000 + args.length,
            stdin: {
              write() {},
              end() {},
            },
            unref() {},
          }
        },
        isAlive() {
          return true
        },
        kill() {},
      },
    })

    try {
      const staleWorker = await harness.runtime.spawnWorker({
        runId: 'demo-20260702-130619',
        role: 'worker',
        nickname: 'back-fixer',
        reason: 'Frontend-only defect: request CTA resolution needs a frontend route fix.',
        scope: 'fix-summary.md',
        prompt: 'Investigate the frontend blocker and report a fix summary.',
      })
      const staleTime = new Date('2026-07-02T10:00:00.000Z')
      fs.utimesSync(staleWorker.logPath, staleTime, staleTime)
      fs.writeFileSync(staleWorker.lastMessagePath, 'Waiting on the frontend route fix.\n')
      fs.utimesSync(staleWorker.lastMessagePath, staleTime, staleTime)
      fs.utimesSync(staleWorker.promptPath, staleTime, staleTime)

      await harness.bus.appendSpawnRequest({
        runId: 'demo-20260702-130619',
        askedBy: 'orchestrator',
        scope: 'demo launch',
        text: 'Start the next demo handoff.',
        context: 'Need the orchestrator to fan out the next workers for the current demo run.',
        requestedRole: 'planner',
        priority: 'blocking',
        tags: ['launch', 'demo', 'orchestration'],
      })

      const result = await harness.client.callTool({
        name: 'run_orchestrator_turn',
        arguments: {
          runId: 'demo-20260702-130619',
          task: 'Repair the demo flow',
          scenario: 'both',
          frontendUrl: 'http://localhost:5174',
        },
      })

      const structuredContent = result.structuredContent as {
        plan: { nextStep: { owner: string; artifact: string } | null } | null
        jobs: Array<{ step: { owner: string; artifact: string } }>
      }

      expect(structuredContent.plan?.nextStep?.owner).toBe('planner')
      expect(structuredContent.jobs.map((job) => job.step.owner)).toEqual(['planner'])
      const openRequests = await harness.bus.listOpenSpawnRequests()
      expect(openRequests.map((request) => request.requestedRole)).toEqual(['planner', 'planner'])
      const activeWorkers = await harness.runtime.listWorkers({ runId: 'demo-20260702-130619', activeOnly: true })
      expect(activeWorkers.map((worker) => worker.role)).toEqual(['worker'])
    } finally {
      await harness.close()
    }
  })

  test('routes infrastructure stalls to the planner through the orchestrator tool', async () => {
    const harness = await createMcpTestHarness({
      processAdapter: {
        spawn(_command, args) {
          return {
            pid: 61000 + args.length,
            stdin: {
              write() {},
              end() {},
            },
            unref() {},
          }
        },
        isAlive() {
          return true
        },
        kill() {},
      },
    })

    try {
      const staleWorker = await harness.runtime.spawnWorker({
        runId: 'demo-20260702-130620',
        role: 'worker',
        nickname: 'front-fixer',
        reason:
          'Docker Playwright version mismatch: the recording image ships Playwright 1.58.2 while the project depends on Playwright 1.61.1.',
        scope: 'fix-summary.md',
        prompt: 'Investigate the infrastructure mismatch and report a fix summary.',
      })
      const staleTime = new Date('2026-07-02T10:00:00.000Z')
      fs.utimesSync(staleWorker.logPath, staleTime, staleTime)
      fs.writeFileSync(staleWorker.lastMessagePath, 'The recorder is blocked by a Docker Playwright version mismatch.\n')
      fs.utimesSync(staleWorker.lastMessagePath, staleTime, staleTime)
      fs.utimesSync(staleWorker.promptPath, staleTime, staleTime)

      const result = await harness.client.callTool({
        name: 'run_orchestrator_turn',
        arguments: {
          runId: 'demo-20260702-130620',
          task: 'Repair the demo recording loop',
          scenario: 'both',
          frontendUrl: 'http://localhost:5174',
        },
      })

      const structuredContent = result.structuredContent as {
        plan: { nextStep: { owner: string; artifact: string } | null } | null
        jobs: Array<{ step: { owner: string; artifact: string } }>
      }

      expect(structuredContent.plan?.nextStep?.owner).toBe('planner')
      expect(structuredContent.jobs.map((job) => job.step.owner)).toEqual(['planner'])
      const openRequests = await harness.bus.listOpenSpawnRequests()
      expect(openRequests.map((request) => request.requestedRole)).toEqual(['planner'])
      const activeWorkers = await harness.runtime.listWorkers({ runId: 'demo-20260702-130620', activeOnly: true })
      expect(activeWorkers.map((worker) => worker.role)).toEqual(['worker'])
    } finally {
      await harness.close()
    }
  })
})
