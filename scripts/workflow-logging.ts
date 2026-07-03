export type WorkflowLogEntry = {
  timestamp: string
  scope: string
  message: string
  details?: Record<string, unknown>
}

export function formatWorkflowLogLine(entry: WorkflowLogEntry): string {
  const details = entry.details ? ` ${JSON.stringify(entry.details)}` : ''
  return `[workflow] ${entry.timestamp} ${entry.scope}: ${entry.message}${details}`
}

