// @vitest-environment node

import * as fs from 'fs'

import { afterEach, describe, expect, test } from 'vitest'

import { createMcpTestHarness, type WorkflowMcpTestHarness } from './helpers/workflow-mcp-test-harness'

const harnesses: WorkflowMcpTestHarness[] = []

afterEach(async () => {
  for (const harness of harnesses.splice(0)) {
    await harness.close()
  }
})

const MANAGED_ARTIFACTS = ['workflow-plan.md', 'recorder-report.md', 'verifier-report.md', 'fix-summary.md', 'final-summary.md']

describe('workflow MCP artifact tools', () => {
  test('collect_workflow_state reports all managed artifacts as missing in a fresh output dir', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({ name: 'collect_workflow_state', arguments: {} })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as {
      outputDir: string
      artifacts: Array<{ name: string; exists: boolean }>
    }
    expect(structuredContent.artifacts.map((artifact) => artifact.name)).toEqual(MANAGED_ARTIFACTS)
    expect(structuredContent.artifacts.every((artifact) => !artifact.exists)).toBe(true)
  })

  test('write_workflow_artifact writes to the managed output dir and the file actually exists on disk', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'write_workflow_artifact',
      arguments: { artifactName: 'workflow-plan.md', content: '# Plan\n\nStep one.' },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as { path: string }
    expect(fs.existsSync(structuredContent.path)).toBe(true)
    expect(fs.readFileSync(structuredContent.path, 'utf8')).toBe('# Plan\n\nStep one.')
  })

  test('read_workflow_artifact reads back content written via write_workflow_artifact in the same server instance', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    await harness.client.callTool({
      name: 'write_workflow_artifact',
      arguments: { artifactName: 'recorder-report.md', content: 'Recorded successfully.' },
    })

    const result = await harness.client.callTool({
      name: 'read_workflow_artifact',
      arguments: { artifactName: 'recorder-report.md' },
    })

    expect(result.isError).toBeFalsy()
    const structuredContent = result.structuredContent as { content: string }
    expect(structuredContent.content).toBe('Recorded successfully.')
  })

  test('write_workflow_artifact rejects an artifact name outside the allowlist', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'write_workflow_artifact',
      arguments: { artifactName: 'not-a-real-artifact.md', content: 'irrelevant' },
    })

    expect(result.isError).toBe(true)
    const [content] = result.content as Array<{ type: string; text: string }>
    expect(content?.text).toContain('Unsupported workflow artifact')
  })

  test('read_workflow_artifact rejects an artifact name outside the allowlist', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    const result = await harness.client.callTool({
      name: 'read_workflow_artifact',
      arguments: { artifactName: 'not-a-real-artifact.md' },
    })

    expect(result.isError).toBe(true)
  })

  test('collect_workflow_state reflects a written artifact\'s size, updatedAt, and preview', async () => {
    const harness = await createMcpTestHarness()
    harnesses.push(harness)

    await harness.client.callTool({
      name: 'write_workflow_artifact',
      arguments: { artifactName: 'verifier-report.md', content: 'All checks passed.' },
    })

    const result = await harness.client.callTool({ name: 'collect_workflow_state', arguments: {} })
    const structuredContent = result.structuredContent as {
      artifacts: Array<{ name: string; exists: boolean; sizeBytes: number | null; updatedAt: string | null; preview: string | null }>
    }
    const verifierArtifact = structuredContent.artifacts.find((artifact) => artifact.name === 'verifier-report.md')

    expect(verifierArtifact?.exists).toBe(true)
    expect(verifierArtifact?.sizeBytes).toBeGreaterThan(0)
    expect(verifierArtifact?.updatedAt).toEqual(expect.any(String))
    expect(verifierArtifact?.preview).toContain('All checks passed.')
  })
})
