import pg from 'pg'
import { afterAll, beforeAll } from 'vitest'
import { fileIndexContract } from './file-index.contract.ts'
import type { FileIndex } from './file-index.ts'
import { postgresFileIndex } from './file-index-postgres.ts'

const url = process.env.WADJET_TEST_DATABASE_URL
if (url === undefined || url === '')
  throw new Error('WADJET_TEST_DATABASE_URL is required to run the docker tests')

const pool = new pg.Pool({ connectionString: url })
let index: FileIndex

beforeAll(async () => {
  index = await postgresFileIndex(pool)
})

afterAll(async () => {
  await pool.end()
})

fileIndexContract('postgresFileIndex', async () => {
  await pool.query('TRUNCATE files')
  return index
})
