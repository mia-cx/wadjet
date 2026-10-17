import type { D1Migration } from '@cloudflare/vitest-plugin'
import type {} from '@cloudflare/vitest-plugin/types'
import type { ReplayFixtures } from './replay.contract.ts'

// The bindings the workers vitest project adds on top of wrangler.jsonc.
declare global {
  namespace Cloudflare {
    interface Env {
      readonly BLOBS: R2Bucket
      readonly DB: D1Database
      readonly FIXTURES: ReplayFixtures
      readonly TEST_MIGRATIONS: D1Migration[]
      readonly [name: `WADJET_${string}`]: string | undefined
    }

    interface GlobalProps {
      mainModule: typeof import('./worker.ts')
    }
  }
}
