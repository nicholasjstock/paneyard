import * as fs from 'fs'

export type LogFileSystem = {
  existsSync(filePath: string): boolean
  readFileSync(filePath: string, encoding: BufferEncoding): string
  statSync(filePath: string): { size: number; mtime: Date }
}

export const defaultLogFileSystem: LogFileSystem = {
  existsSync(filePath) {
    return fs.existsSync(filePath)
  },
  readFileSync(filePath, encoding) {
    return fs.readFileSync(filePath, encoding)
  },
  statSync(filePath) {
    return fs.statSync(filePath)
  },
}

export type FullLogResult = {
  content: string | null
  truncated: boolean
  totalBytes: number
}

export function readFullLogContent(
  fileSystem: LogFileSystem,
  filePath: string,
  maxChars: number
): FullLogResult {
  if (!fileSystem.existsSync(filePath)) {
    return { content: null, truncated: false, totalBytes: 0 }
  }

  const totalBytes = fileSystem.statSync(filePath).size
  const content = fileSystem.readFileSync(filePath, 'utf8')

  if (content.length <= maxChars) {
    return { content, truncated: false, totalBytes }
  }

  const rawSlice = content.slice(content.length - maxChars)
  const firstNewline = rawSlice.indexOf('\n')
  const trimmedSlice = firstNewline === -1 ? rawSlice : rawSlice.slice(firstNewline + 1)

  return { content: trimmedSlice, truncated: true, totalBytes }
}

export function readTailLines(
  fileSystem: Pick<LogFileSystem, 'existsSync' | 'readFileSync'>,
  filePath: string,
  lineCount: number
): string | null {
  if (!fileSystem.existsSync(filePath)) {
    return null
  }

  const contents = fileSystem.readFileSync(filePath, 'utf8')
  const lines = contents.replace(/\r?\n$/, '').split(/\r?\n/)
  const tail = lines.slice(Math.max(0, lines.length - lineCount)).filter(Boolean)
  return tail.length > 0 ? `${tail.join('\n')}\n` : null
}
