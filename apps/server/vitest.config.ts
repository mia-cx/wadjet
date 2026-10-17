import { fileURLToPath, URL } from 'node:url'
import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-plugin'
import { defineConfig } from 'vitest/config'
import { loadFixtures, REPLAY_ENV } from './src/test-helpers.ts'

// Miniflare's `bindings` wants its Json type; the fixtures are plain JSON.
type Json = string | number | boolean | null | Json[] | { [key: string]: Json }

export default defineConfig({
  test: {
    projects: [
      {
        test: {
          name: 'node',
          include: ['src/**/*.test.ts'],
          exclude: ['src/**/*.worker.test.ts', 'src/**/*.docker.test.ts'],
        },
      },
      {
        plugins: [
          cloudflareTest({
            wrangler: { configPath: './wrangler.jsonc' },
            miniflare: {
              bindings: {
                ...REPLAY_ENV,
                FIXTURES: loadFixtures() as unknown as Json,
                TEST_MIGRATIONS: await readD1Migrations(
                  fileURLToPath(new URL('./drizzle', import.meta.url)),
                ),
              },
            },
          }),
        ],
        test: {
          name: 'workers',
          include: ['src/**/*.worker.test.ts'],
          // @cloudflare/vitest-plugin@1.4.0 breaks on vitest's fs module cache
          // (workers-sdk #16237); disable it for this project.
          fsModuleCache: false,
          setupFiles: ['./src/worker-test.setup.ts'],
        },
      },
    ],
  },
})
