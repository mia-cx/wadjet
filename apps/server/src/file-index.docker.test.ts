import pg from 'pg'
import { afterAll, beforeAll, describe, it } from 'vitest'
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

describe('postgresFileIndex', () => {
  it('initializes concurrently on a fresh database', async () => {
    await pool.query('DROP TABLE IF EXISTS files')
    await pool.query('DROP SCHEMA IF EXISTS drizzle CASCADE')
    const a = new pg.Pool({ connectionString: url })
    const b = new pg.Pool({ connectionString: url })
    try {
      await Promise.all([postgresFileIndex(a), postgresFileIndex(b)])
    } finally {
      await Promise.all([a.end(), b.end()])
    }
  })
})
