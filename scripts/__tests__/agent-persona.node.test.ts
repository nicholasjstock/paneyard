// @vitest-environment node

import { describe, expect, test } from 'vitest'

import { buildWorkerPromptWithPersona, loadAgentPersona } from '../agent-persona'

type FakeFileSystem = {
  existsSync: (filePath: string) => boolean
  readFileSync: (filePath: string, encoding: string) => string
}

function makeFakeFileSystem(files: Record<string, string>): FakeFileSystem {
  return {
    existsSync: (filePath) => filePath in files,
    readFileSync: (filePath) => files[filePath] ?? '',
  }
}

describe('loadAgentPersona', () => {
  test('reads the role .toml file content when it exists', () => {
    const fileSystem = makeFakeFileSystem({
      '/repo/.codex/agents/worker.toml': 'name = "worker"\ndeveloper_instructions = "Own frontend writes only."',
    })

    const persona = loadAgentPersona('/repo', 'worker', fileSystem)

    expect(persona).toContain('Own frontend writes only.')
  })

  test('returns null when the role has no .toml file', () => {
    const fileSystem = makeFakeFileSystem({})

    const persona = loadAgentPersona('/repo', 'unknown_role', fileSystem)

    expect(persona).toBeNull()
  })
})

describe('buildWorkerPromptWithPersona', () => {
  test('prepends the persona before the task prompt when a persona exists', () => {
    const fileSystem = makeFakeFileSystem({
      '/repo/.codex/agents/planner.toml': 'name = "planner"\ndeveloper_instructions = "Own planning only."',
    })

    const enriched = buildWorkerPromptWithPersona({
      rootDir: '/repo',
      role: 'planner',
      prompt: 'Report on run-1.',
      fileSystem,
    })

    expect(enriched).toContain('Own planning only.')
    expect(enriched).toContain('Current task:')
    expect(enriched).toContain('Report on run-1.')
    expect(enriched.indexOf('Own planning only.')).toBeLessThan(enriched.indexOf('Report on run-1.'))
  })

  test('returns the prompt unchanged when no persona file exists', () => {
    const fileSystem = makeFakeFileSystem({})

    const enriched = buildWorkerPromptWithPersona({
      rootDir: '/repo',
      role: 'unknown_role',
      prompt: 'Report on run-1.',
      fileSystem,
    })

    expect(enriched).toBe('Report on run-1.')
  })
})
