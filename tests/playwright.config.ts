import { defineConfig, devices } from '@playwright/test';

/**
 * Playwright config for testing VS Code Server web UI.
 *
 * Environment variables:
 *   BASE_URL          — VS Code Server HTTPS base (default: https://127.0.0.1:8560)
 *   VSCODE_TOKEN      — connection token (fallback if TOKEN_FILE not found)
 *   VSCODE_TOKEN_FILE — path to token file inside container (default: /home/vscode/.vscode-token)
 *   WORKSPACE_FOLDER  — workspace folder path (default: /workspace)
 */
export default defineConfig({
  testDir: './',
  testMatch: '*.spec.ts',
  timeout: 90_000,
  expect: { timeout: 20_000 },
  fullyParallel: false,
  retries: 0,
  reporter: [['list'], ['html', { open: 'never', outputFolder: 'report' }]],
  use: {
    ignoreHTTPSErrors: true,  // self-signed certs
    bypassCSP: true,
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'], headless: true },
    },
  ],
});
