import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll } from 'vitest'
import { fileIndexContract } from './file-index.contract.ts'
import { memoryFileIndex } from './file-index.ts'
import { sqliteFileIndex } from './file-index-sqlite.ts'

fileIndexContract('memoryFileIndex', memoryFileIndex)

const dir = mkdtempSync(join(tmpdir(), 'wadjet-index-'))
afterAll(() => rmSync(dir, { recursive: true, force: true }))
fileIndexContract('sqliteFileIndex', () =>
  sqliteFileIndex(join(dir, `wadjet-${crypto.randomUUID()}.db`)),
)
