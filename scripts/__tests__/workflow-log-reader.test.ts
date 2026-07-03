import { describe, expect, test } from 'vitest'

import { readFullLogContent, readTailLines, type LogFileSystem } from '../workflow-log-reader'

function createMemoryFs(files: Record<string, string> = {}): LogFileSystem {
  const store = new Map<string, string>(Object.entries(files))

  return {
    existsSync(filePath) {
      return store.has(filePath)
    },
    readFileSync(filePath) {
      const content = store.get(filePath)
      if (content === undefined) {
        throw new Error(`missing file: ${filePath}`)
      }
      return content
    },
    statSync(filePath) {
      const content = store.get(filePath)
      if (content === undefined) {
        throw new Error(`missing file: ${filePath}`)
      }
      return { size: content.length, mtime: new Date('2026-07-01T00:00:00.000Z') }
    },
  }
}

describe('readFullLogContent', () => {
  test('returns full content and truncated:false when the file is within the cap', () => {
    const fileSystem = createMemoryFs({ '/log.txt': 'line one\nline two\n' })

    expect(readFullLogContent(fileSystem, '/log.txt', 1000)).toEqual({
      content: 'line one\nline two\n',
      truncated: false,
      totalBytes: 18,
    })
  })

  test('returns the trailing slice, truncated:true, and the real totalBytes when the file exceeds the cap', () => {
    const content = `${'a'.repeat(50)}\n${'b'.repeat(50)}\n${'c'.repeat(50)}\n`
    const fileSystem = createMemoryFs({ '/log.txt': content })

    const result = readFullLogContent(fileSystem, '/log.txt', 60)

    expect(result.truncated).toBe(true)
    expect(result.totalBytes).toBe(content.length)
    expect(result.content).not.toBeNull()
    expect(content.endsWith(result.content as string)).toBe(true)
  })

  test('trims the truncated slice to a line boundary', () => {
    const content = `${'a'.repeat(50)}\n${'b'.repeat(50)}\n${'c'.repeat(50)}\n`
    const fileSystem = createMemoryFs({ '/log.txt': content })

    const result = readFullLogContent(fileSystem, '/log.txt', 60)

    expect(result.content?.startsWith('a')).toBe(false)
    expect(result.content?.startsWith('\n')).toBe(false)
  })

  test('returns null content for a missing file', () => {
    const fileSystem = createMemoryFs()

    expect(readFullLogContent(fileSystem, '/missing.txt', 1000)).toEqual({
      content: null,
      truncated: false,
      totalBytes: 0,
    })
  })
})

describe('readTailLines', () => {
  test('returns the last N non-empty lines', () => {
    const fileSystem = createMemoryFs({ '/log.txt': 'one\ntwo\nthree\nfour\n' })

    expect(readTailLines(fileSystem, '/log.txt', 2)).toBe('three\nfour\n')
  })

  test('returns null for a missing file', () => {
    const fileSystem = createMemoryFs()

    expect(readTailLines(fileSystem, '/missing.txt', 2)).toBeNull()
  })
})
