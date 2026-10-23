import { defineConfig } from '@playwright/test';

// Browser tests of polar-ui, through edge-service, against the stack that
// `development/script/smoke-test.sh up edge` starts. Some tests break parts of that stack for a
// while, so the tests run one at a time, in file order. Run them from this directory:
//
//   npm ci && npx playwright install chromium-headless-shell
//   npx playwright test
//
// Environment:
//   UI_BASE_URL     edge-service (default http://localhost:9000)
//   UI_TEST_OUTPUT  directory for traces and screenshots of failed tests (default test-results)
//   UI_TEST_JSON    also write the results to this file with the JSON reporter
//   UI_UNDO_FILE    file to note each container a test stops or pauses in, until it's restored
export default defineConfig({
  testDir: 'tests',
  outputDir: process.env.UI_TEST_OUTPUT ?? 'test-results',
  workers: 1,
  fullyParallel: false,
  retries: 0,
  timeout: 60_000,
  expect: { timeout: 10_000 },
  reporter: process.env.UI_TEST_JSON
    ? [['list'], ['json', { outputFile: process.env.UI_TEST_JSON }]]
    : [['list']],
  use: {
    baseURL: process.env.UI_BASE_URL ?? 'http://localhost:9000',
    browserName: 'chromium',
    headless: true,
    // Keycloak's issuer, and so its login page, is host.docker.internal:8080, which only
    // resolves inside the containers. Its port is published on the host.
    launchOptions: { args: ['--host-resolver-rules=MAP host.docker.internal 127.0.0.1'] },
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
});
