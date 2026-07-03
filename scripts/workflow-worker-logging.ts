import { formatWorkflowLogLine } from './workflow-logging'

export type WorkflowWorkerLifecycleEvent = {
  timestamp: string
  event: 'spawned' | 'stopped'
  workerId: string
  runId: string
  role: string
  nickname: string
  pid: number
  scope: string
  reason: string
  command?: string
  status?: string
  stopReason?: string | null
}

export function formatWorkflowWorkerLifecycleLine(event: WorkflowWorkerLifecycleEvent): string {
  return formatWorkflowLogLine({
    timestamp: event.timestamp,
    scope: 'worker:lifecycle',
    message: `${event.event} ${event.nickname}`,
    details: {
      workerId: event.workerId,
      runId: event.runId,
      role: event.role,
      nickname: event.nickname,
      pid: event.pid,
      scope: event.scope,
      reason: event.reason,
      command: event.command ?? null,
      status: event.status ?? null,
      stopReason: event.stopReason ?? null,
    },
  })
}
