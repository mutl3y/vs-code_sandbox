/**
 * Playwright E2E tests for VS Code Server Web UI.
 *
 * Pattern follows /workspace/skills-review-and-polish/tests/e2e/ which is a
 * known-working Playwright + VS Code in container setup.
 *
 * Prerequisites:
 *   1. Dev container running:  ./scripts/launcher-dev.sh create 1 /workspace
 *   2. Token is read from the container automatically.
 *
 * Run:
 *   npx playwright test --config tests/playwright.config.ts
 */
import { test, expect, type Page, type BrowserContext } from '@playwright/test';
import { readFileSync } from 'fs';
import { execSync } from 'child_process';

test.describe.configure({ mode: 'serial' });

// ── Configuration ────────────────────────────────────────────────────────────
const BASE_URL = process.env.BASE_URL ?? 'https://127.0.0.1:8560';
const CONTAINER = process.env.VSCODE_CONTAINER ?? 'vscode-dev-1';
const FOLDER = process.env.WORKSPACE_FOLDER ?? '/workspace';
const VSCODE_URL = `${BASE_URL}/?folder=${encodeURIComponent(FOLDER)}`;

let page: Page;
let context: BrowserContext;

// ── Helpers (matching skills-review-and-polish patterns) ──────────────────────

async function waitForVSCode(page: Page) {
  await page.waitForSelector('.monaco-workbench', { timeout: 30_000 });

  // Handle workspace trust dialog — dialog may or may not appear
  const trustBtn = page.getByRole('button', { name: 'Yes, I trust the authors' });
  try {
    await trustBtn.waitFor({ state: 'visible', timeout: 6_000 });
    await trustBtn.click();
    await page.locator('.monaco-dialog-modal-block').waitFor({ state: 'hidden', timeout: 5_000 });
  } catch {
    // Dialog didn't appear — already trusted
  }

  // Dismiss "Get Started" / Welcome dialog if present
  try {
    await page.keyboard.press('Escape');
    await page.locator('.monaco-dialog-modal-block').waitFor({ state: 'hidden', timeout: 3_000 });
  } catch {
    // No dialog — continue
  }

  // Wait for both workbench and activity bar to be fully rendered
  await page.waitForFunction(() => {
    const workbench = document.querySelector('.monaco-workbench');
    const activityBar = document.querySelector('.monaco-workbench .part.activitybar');
    return !!workbench && !!activityBar;
  }, { timeout: 30_000 });
}

async function openCommandPalette(page: Page) {
  await page.keyboard.press('Control+Shift+P');
  await page.waitForSelector('.quick-input-box input', { timeout: 5_000 });
  await page.waitForTimeout(300); // let palette fully render
}

async function runCommand(page: Page, command: string) {
  await openCommandPalette(page);
  const titlePart = command.split(':')[1]?.trim() ?? command;
  await page.fill('.quick-input-box input', `> ${titlePart}`);
  const item = page.locator('.quick-input-list .monaco-list-row .label-name', { hasText: titlePart });
  await expect(item.first()).toBeVisible({ timeout: 2_000 });
  await page.keyboard.press('Enter');
  await page.waitForTimeout(500);
}

// ── Setup / Teardown ─────────────────────────────────────────────────────────

test.beforeAll(async ({ browser }) => {
  context = await browser.newContext();
  page = await context.newPage();

  // Read connection token from the running container via podman exec
  let token = process.env.VSCODE_TOKEN ?? '';
  if (!token) {
    try {
      token = execSync(
        `podman exec ${CONTAINER} cat /home/vscode/.vscode-token`,
        { encoding: 'utf8', timeout: 5000 }
      ).trim();
    } catch {
      console.warn(`[test] Could not read token from container ${CONTAINER}`);
    }
  }

  // Step 1: Authenticate by navigating to base URL with token
  const authUrl = token ? `${BASE_URL}/?tkn=${token}` : BASE_URL;
  console.log(`[test] Authenticating: ${BASE_URL}/?tkn=${token ? '***' : 'NONE'}&...`);
  await page.goto(authUrl, { waitUntil: 'domcontentloaded', timeout: 15_000 });

  // Step 2: Navigate to the workspace folder
  await page.goto(VSCODE_URL, { waitUntil: 'domcontentloaded', timeout: 15_000 });

  // Wait for workbench + handle trust dialog
  await waitForVSCode(page);
});

test.afterAll(async () => {
  await page?.close();
  await context?.close();
});

// ── Core Tests ───────────────────────────────────────────────────────────────

test.describe('VS Code Server Web — Core', () => {
  test('page loads and VS Code workbench initialises', async () => {
    await expect(page.locator('.monaco-workbench')).toBeVisible();
  });

  test('title contains "Visual Studio Code"', async () => {
    const title = await page.title();
    expect(title).toContain('Visual Studio Code');
  });

  test('activity bar is visible', async () => {
    await expect(page.locator('.activitybar')).toBeVisible();
  });

  test('status bar is visible', async () => {
    await expect(page.locator('.statusbar')).toBeVisible();
  });

  test('no error overlay or crash screen', async () => {
    await expect(page.locator('.dialog-message-danger')).toHaveCount(0);
  });
});

// ── Authentication Tests ─────────────────────────────────────────────────────

test.describe('VS Code Server Web — Authentication', () => {
  test('workbench loaded successfully (auth passed)', async () => {
    await expect(page.locator('.monaco-workbench')).toBeVisible();
  });
});

// ── File Explorer Tests ──────────────────────────────────────────────────────

test.describe('VS Code Server Web — File Explorer', () => {
  test('Explorer view is accessible from the activity bar', async () => {
    // Use keyboard shortcut to open Explorer (more reliable than clicking)
    await page.keyboard.press('Control+Shift+E');
    // Wait for sidebar to become visible (not hidden/empty)
    await page.waitForFunction(() => {
      const sidebar = document.querySelector('.sidebar');
      return sidebar && !sidebar.classList.contains('empty') && sidebar.clientHeight > 0;
    }, { timeout: 10_000 });
    await expect(page.locator('.sidebar').first()).toBeVisible({ timeout: 10_000 });
  });
});

// ── Terminal Tests ───────────────────────────────────────────────────────────

// ── Terminal Tests ───────────────────────────────────────────────────────────
// TODO: Terminal tests skipped — xterm.js renders via canvas; reading terminal
// output requires navigating the xterm buffer API which needs further research.
// See HANDOVER.md §4 and the reference suite (skills-review-and-polish) which
// does not test terminal output either.

test.describe('VS Code Server Web — Terminal', () => {
  test.fixme('terminal can be opened via keyboard shortcut', async () => {
    await page.keyboard.press('Control+B');
    await page.waitForTimeout(300);
    await page.keyboard.press('Control+`');
  });

  test.fixme('terminal executes a command', async () => {
    // xterm renders via canvas — need xterm buffer API to read output
  });

  test.fixme('terminal uses bash shell', async () => {
    // xterm renders via canvas — need xterm buffer API to read output
  });
});

// ── Secret Storage Tests ─────────────────────────────────────────────────────

test.describe('VS Code Server Web — Secret Storage', () => {
  test('document secret storage cookie status', async () => {
    const cookies = await context.cookies();
    const secretCookies = cookies.filter(c =>
      c.name.includes('vscode-secret') || c.name.includes('vscode-cli-secret')
    );
    console.log('Secret cookies found:', secretCookies.map(c => c.name));
    if (secretCookies.length === 0) {
      console.warn('No secret storage cookies — secrets may use in-memory fallback');
    }
    // Informational — always passes
    expect(true).toBe(true);
  });
});

// ── HTTPS Tests ──────────────────────────────────────────────────────────────

test.describe('VS Code Server Web — HTTPS', () => {
  test('HTTPS connection works with self-signed cert', async () => {
    // We already connected — just verify the context is still alive
    const response = await page.goto(VSCODE_URL, { waitUntil: 'domcontentloaded', timeout: 15_000 });
    expect(response?.status()).toBeLessThan(400);
    await waitForVSCode(page);
  });
});
