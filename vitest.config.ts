import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    environment: 'node',
    globals: true,
    include: ['scripts/__tests__/**/*.test.ts'],
  },
})
