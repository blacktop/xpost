import { defineConfig } from "vitest/config";

// Most tests drive a real headless browser, usually through the helper process.
export default defineConfig({
  test: {
    testTimeout: 90_000,
    hookTimeout: 30_000,
    fileParallelism: false,
  },
});
