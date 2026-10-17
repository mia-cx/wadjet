import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    include: ['src/**/*.docker.test.ts'],
  },
})
