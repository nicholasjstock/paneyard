import * as fs from 'fs'
import * as path from 'path'

type PersonaFileSystem = {
  existsSync(filePath: string): boolean
  readFileSync(filePath: string, encoding: BufferEncoding): string
}

const defaultPersonaFileSystem: PersonaFileSystem = {
  existsSync(filePath) {
    return fs.existsSync(filePath)
  },
  readFileSync(filePath, encoding) {
    return fs.readFileSync(filePath, encoding)
  },
}

export function loadAgentPersona(
  rootDir: string,
  role: string,
  fileSystem: PersonaFileSystem = defaultPersonaFileSystem
): string | null {
  const personaPath = path.join(rootDir, '.codex', 'agents', `${role}.toml`)

  if (!fileSystem.existsSync(personaPath)) {
    return null
  }

  return fileSystem.readFileSync(personaPath, 'utf8')
}

export function buildWorkerPromptWithPersona(args: {
  rootDir: string
  role: string
  prompt: string
  fileSystem?: PersonaFileSystem
}): string {
  const persona = loadAgentPersona(args.rootDir, args.role, args.fileSystem)

  if (!persona) {
    return args.prompt
  }

  return `${persona}\n\nCurrent task:\n${args.prompt}`
}
