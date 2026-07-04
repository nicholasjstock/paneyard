// @vitest-environment node

import * as fs from 'fs'
import * as os from 'os'
import * as path from 'path'

import { afterEach, describe, expect, test } from 'vitest'

import { inspectWorkflowWorkers, inspectWorkflowWorkersList } from '../workflow-worker-monitor'

const tempDirs: string[] = []

afterEach(() => {
  for (const tempDir of tempDirs.splice(0)) {
    fs.rmSync(tempDir, { recursive: true, force: true })
  }
})

describe('workflow worker monitor', () => {
  test('lists workers with their log and last-message paths', () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'demo-worker-monitor-'))
    tempDirs.push(tempDir)

    const storagePath = path.join(tempDir, 'workers.json')
    fs.writeFileSync(
      storagePath,
      JSON.stringify(
        {
          workers: [
            {
              workerId: 'worker-1',
              runId: 'demo-run',
              role: 'worker',
              nickname: 'front-fixer',
              reason: 'Fix the mobile cursor.',
              scope: 'record-demo',
              status: 'stopped',
              pid: 41000,
              promptPath: path.join(tempDir, 'front-fixer.prompt.txt'),
              logPath: path.join(tempDir, 'front-fixer.log'),
              lastMessagePath: path.join(tempDir, 'front-fixer.last-message.txt'),
              envPath: path.join(tempDir, 'front-fixer.env.json'),
              command: 'codex',
              args: ['exec', '-'],
              startedAt: '2026-07-02T10:00:00.000Z',
              stoppedAt: '2026-07-02T10:01:00.000Z',
              stopReason: 'Done',
            },
            {
              workerId: 'worker-2',
              runId: 'demo-run',
              role: 'worker',
              nickname: 'demo-verifier',
              reason: 'Verify the capture.',
              scope: 'verifier-report.md',
              status: 'stopped',
              pid: 41001,
              promptPath: path.join(tempDir, 'demo-verifier.prompt.txt'),
              logPath: path.join(tempDir, 'demo-verifier.log'),
              lastMessagePath: path.join(tempDir, 'demo-verifier.last-message.txt'),
              envPath: path.join(tempDir, 'demo-verifier.env.json'),
              command: 'codex',
              args: ['exec', '-'],
              startedAt: '2026-07-02T10:02:00.000Z',
              stoppedAt: '2026-07-02T10:03:00.000Z',
              stopReason: 'Verified',
            },
          ],
        },
        null,
        2
      )
    )

    const output = inspectWorkflowWorkersList({ storagePath })

    expect(output).toContain(`Workflow workers: ${storagePath}`)
    expect(output).toContain('Workers: 2')
    expect(output).toContain('front-fixer')
    expect(output).toContain('front-fixer.log')
    expect(output).toContain('demo-verifier')
  })

  test('shows a specific worker log tail and latest message', () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'demo-worker-monitor-'))
    tempDirs.push(tempDir)

    const storagePath = path.join(tempDir, 'workers.json')
    const logPath = path.join(tempDir, 'front-fixer.log')
    const lastMessagePath = path.join(tempDir, 'front-fixer.last-message.txt')
    fs.writeFileSync(
      storagePath,
      JSON.stringify(
        {
          workers: [
            {
              workerId: 'worker-1',
              runId: 'demo-run',
              role: 'worker',
              nickname: 'front-fixer',
              reason: 'Fix the mobile cursor.',
              scope: 'record-demo',
              status: 'stopped',
              pid: 41000,
              promptPath: path.join(tempDir, 'front-fixer.prompt.txt'),
              logPath,
              lastMessagePath,
              envPath: path.join(tempDir, 'front-fixer.env.json'),
              command: 'codex',
              args: ['exec', '-'],
              startedAt: '2026-07-02T10:00:00.000Z',
              stoppedAt: '2026-07-02T10:01:00.000Z',
              stopReason: 'Done',
            },
          ],
        },
        null,
        2
      )
    )
    fs.writeFileSync(
      logPath,
      [
        '[workflow] 2026-07-02T10:00:00.000Z worker:lifecycle: spawned front-fixer {"pid":41000}',
        'worker output line 1',
        'worker output line 2',
      ].join('\n')
    )
    fs.writeFileSync(lastMessagePath, 'Latest worker message')

    const output = inspectWorkflowWorkers({ storagePath, nickname: 'front-fixer', tail: 2 })

    expect(output).toContain('Worker: front-fixer')
    expect(output).toContain('Status: stopped')
    expect(output).toContain('Recent log (2 lines):')
    expect(output).toContain('worker output line 1')
    expect(output).toContain('worker output line 2')
    expect(output).toContain('Latest message:')
    expect(output).toContain('Latest worker message')
  })
})
