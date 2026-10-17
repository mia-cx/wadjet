import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll } from 'vitest'
import { uploadIndexContract } from './upload-index.contract.ts'
import { memoryUploadIndex } from './upload-index.ts'
import { sqliteUploadIndex } from './upload-index-sqlite.ts'

uploadIndexContract('memoryUploadIndex', memoryUploadIndex)

const dir = mkdtempSync(join(tmpdir(), 'wadjet-uploads-'))
afterAll(() => rmSync(dir, { recursive: true, force: true }))
uploadIndexContract('sqliteUploadIndex', () =>
  sqliteUploadIndex(join(dir, `uploads-${crypto.randomUUID()}.db`)),
)
