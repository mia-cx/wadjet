import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    exclude: ['**/*.docker.test.ts', '**/node_modules/**'],
  },
})
