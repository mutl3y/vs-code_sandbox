# Handover: VS Code in Container — Latest VS Code Cleanup

**Branch:** `feat/latest-vscode-cleanup` (commit `26df691`)
**Date:** 10 June 2026

---

## 1. What Was Done

Rebuilt the Dockerfile on a development branch to test whether the latest VS Code Server (`server-linux-x64-web`) supports mint-proxy and `vscode:///` URIs natively — meaning our three custom workarounds can be removed.

### 3 Workarounds Commented Out (not deleted)

| # | Workaround | File Location | Why It Was Needed |
|---|-----------|---------------|-------------------|
| 1 | `sed` patch on `getCwdResource()` | `Dockerfile` lines ~108-130 | Catches `ENOPRO` when `file://` provider missing in web mode |
| 2 | `mint-proxy.js` + startup references | `Dockerfile` lines ~93-97 (COPY), ~249-252 (startup) | Implements `ServerKeyedAESCrypto` key-minting protocol |
| 3 | `config/vscode-settings.json` + injection loop | `Dockerfile` lines ~83-88 (COPY), ~148-160 (startup) | Disables workspace trust prompts |

All code is commented out with `WHY COMMENTED` annotations and rollback instructions. Each section has explicit comments showing how to re-enable if needed.

### Additional Changes

- `nginx` `proxy_pass` changed from `${PROXY_PORT}` → `${VSCODE_PORT}` (direct to VS Code)
- `wait`/`kill` blocks updated to remove `PROXY_PID`
- New file: `scripts/launcher-dev.sh` — isolated dev launcher (ports 8560-8562, container names `vscode-dev-N`, volumes `vscode-dev-*`)

### What Was NOT Changed

- Base image: `mcr.microsoft.com/vscode/devcontainers/base:ubuntu-22.04` (same)
- `scripts/launcher.sh` (production) — untouched
- `scripts/mint-proxy.js` — file still exists, just not COPYed in dev Dockerfile
- `config/vscode-settings.json` — file still exists, just not COPYed in dev Dockerfile

---

## 2. Build & Session Status

**Image:** `vscode-agent:dev` — built successfully
**Session:** `vscode-dev-1` — running on port 8560 (HTTPS)

```bash
# Rebuild if needed
./scripts/launcher-dev.sh build

# Create session
./scripts/launcher-dev.sh create 1 /tmp/vscode-dev-workspace

# Get token
podman exec vscode-dev-1 cat /home/vscode/.vscode-token
```

**IMPORTANT:** Do NOT use `scripts/launcher.sh` — that's the production launcher and will affect your active sessions. Use `scripts/launcher-dev.sh` exclusively.

---

## 3. Test Status — 6/12 Passing

### ✅ Passing (6 tests)

| Test | What It Verifies |
|------|-----------------|
| Core: page loads and workbench initialises | `.monaco-workbench` selector present |
| Core: title contains "Visual Studio Code" | Page title correct |
| Core: activity bar is visible | `.activitybar` element rendered |
| Core: status bar is visible | `.statusbar` element rendered |
| Core: no error overlay | No `.dialog-message-danger` elements |
| Authentication: workbench loaded | Auth succeeded (workbench visible) |

### ❌ Failing (1 test — blocks 5 remaining)

| Test | Failure Reason |
|------|---------------|
| File Explorer: Explorer view accessible | `<div class="monaco-dialog-modal-block dimmed">` intercepts pointer events |

**Root cause:** A dialog modal is blocking clicks on the activity bar. This is the **"Get Started" / Welcome dialog** that VS Code shows on first launch. The screenshot shows a greyed-out overlay covering the entire UI.

### ⏳ Not Run (5 tests — blocked by Explorer failure)

| Test | What It Would Verify |
|------|---------------------|
| Terminal: open via command palette | `runCommand()` helper works |
| Terminal: executes a command | `echo "playwright-test-ok"` appears in terminal |
| Terminal: uses bash shell | `$SHELL` resolves to `/bin/bash` |
| Secret Storage: cookie status | `vscode-secret*` cookies present (informational) |
| HTTPS: connection works | Self-signed cert accepted |

---

## 4. How to Fix the Failing Test

### The Problem

The "Get Started" welcome dialog appears as a modal overlay (`monaco-dialog-modal-block dimmed`) that blocks all pointer events on the activity bar.

### The Fix

Dismiss the dialog in `waitForVSCode()` by pressing `Escape` after the trust dialog is handled. Add this after the trust dialog block:

```typescript
async function waitForVSCode(page: Page) {
  await page.waitForSelector('.monaco-workbench', { timeout: 30_000 });

  // Handle workspace trust dialog
  const trustBtn = page.getByRole('button', { name: 'Yes, I trust the authors' });
  try {
    await trustBtn.waitFor({ state: 'visible', timeout: 6_000 });
    await trustBtn.click();
    await page.locator('.monaco-dialog-modal-block').waitFor({ state: 'hidden', timeout: 5_000 });
  } catch { /* already trusted */ }

  // Dismiss "Get Started" / Welcome dialog if present
  try {
    await page.keyboard.press('Escape');
    await page.locator('.monaco-dialog-modal-block').waitFor({ state: 'hidden', timeout: 3_000 });
  } catch { /* no dialog */ }

  // Wait for workbench + activity bar fully rendered
  await page.waitForFunction(() => {
    const workbench = document.querySelector('.monaco-workbench');
    const activityBar = document.querySelector('.monaco-workbench .part.activitybar');
    return !!workbench && !!activityBar;
  }, { timeout: 30_000 });
}
```

**Alternative approach** (if Escape doesn't work): Use `{ force: true }` on clicks to bypass the modal check, or use `page.locator('.monaco-dialog-block .codicon-close')` to find the close button.

---

## 5. Timing Conventions (from skills-review-and-polish)

**Reference:** `/workspace/skills-review-and-polish/tests/e2e/`

All timing values below are taken from the working reference test suite. Match these exactly:

### Timeout Values (selector waits)

| Pattern | Timeout | Use When |
|---------|---------|----------|
| `.monaco-workbench` | `30_000` | Initial page load — VS Code is slow |
| Trust dialog visibility | `6_000` | May or may not appear |
| Dialog hidden | `5_000` | After clicking trust button |
| `.quick-input-box input` | `5_000` | Command palette open |
| `.quick-input-list .monaco-list-row` | `2_000` to `3_000` | Command palette items |
| `.monaco-editor` (focused) | `3_000` to `5_000` | Editor loaded |
| `.markers-panel` | `3_000` | Problems panel |
| `.settings-editor` | `5_000` | Settings page loaded |
| `goto()` domcontentloaded | `10_000` (auth) / `15_000` (workspace) | Navigation |

### Sleep Values (arbitrary waits)

| Pattern | Duration | Use When |
|---------|----------|----------|
| Command palette render | `300ms` | After pressing Ctrl+Shift+P, before typing |
| After `page.fill()` in palette | `300ms` | Let filtering settle |
| After command palette Enter | `500ms` | Let command execute |
| Shell initialisation | `1_000ms` to `1_500ms` | After opening terminal |
| Settings page settle | `1_500ms` | After navigating to settings |
| General UI settle | `1_000ms` | After any navigation or action |

### Patterns to Follow

```typescript
// ✅ CORRECT — from reference suite
await page.keyboard.press('Control+Shift+P');
await page.waitForSelector('.quick-input-box input', { timeout: 5_000 });
await page.waitForTimeout(300);  // let palette fully render
await page.fill('.quick-input-box input', `> ${command}`);
const item = page.locator('.quick-input-list .monaco-list-row .label-name', { hasText: command });
await expect(item.first()).toBeVisible({ timeout: 2_000 });
await page.keyboard.press('Enter');
await page.waitForTimeout(500);

// ❌ WRONG — too many arbitrary sleeps, missing selector waits
await page.keyboard.press('Control+Shift+P');
await page.waitForTimeout(1000);  // don't just sleep — use selector wait
await page.keyboard.type('Terminal: Create New Terminal');
await page.waitForTimeout(500);
await page.keyboard.press('Enter');
await page.waitForTimeout(2000);  // too long — use selector wait instead
```

### Golden Rule

**Prefer `waitForSelector` / `expect().toBeVisible()` over `waitForTimeout()`.** Only use `waitForTimeout()` for short settling periods (300-500ms) after the selector has already been found. Never use timeouts longer than 1500ms as a substitute for a proper selector wait.

---

## 6. DOM Selectors (verified working)

These selectors were confirmed working against VS Code Server `server-linux-x64-web` (latest stable):

| Selector | Element | Notes |
|----------|---------|-------|
| `.monaco-workbench` | Root workbench container | Primary load indicator |
| `.activitybar` | Activity bar (left sidebar icons) | |
| `.statusbar` | Status bar (bottom) | |
| `.sidebar` | Sidebar container | |
| `.sidebar .pane-body` | Sidebar content pane | |
| `.part.activitybar` | Activity bar (alternative, with `.part` prefix) | Used in `waitForFunction` |
| `.quick-input-widget` | Command palette widget | |
| `.quick-input-box input` | Command palette input field | |
| `.quick-input-list .monaco-list-row` | Command palette list items | |
| `.quick-input-list .monaco-list-row .label-name` | Command palette item labels | |
| `.terminal` | Terminal panel | May need `.first()` if multiple |
| `.dialog-message-danger` | Error overlay (should be 0) | |
| `.monaco-dialog-modal-block` | Modal overlay (blocks clicks) | **This is what's blocking tests** |
| `.monaco-dialog-block .codicon-close` | Dialog close button (if present) | |

**Body class in server mode:** `agent-status-enabled unified-agents-bar` (NOT `body.vscode`)

---

## 7. Architecture Notes

### Container Stack (dev)

```
Browser → nginx (TLS :8560) → VS Code Server (:9210)
```

**No mint-proxy** — nginx proxies directly to VS Code.

### Port Map (dev vs production)

| | Production | Dev |
|---|---|---|
| HTTPS | 8550-8552 | **8560-8562** |
| VS Code (internal) | 9200-9202 | **9210-9212** |
| Container names | `vscode-ssl-v2-N` | `vscode-dev-N` |
| Volumes | `vscode-ssl-v2-*` | `vscode-dev-*` |

### Two-Step Navigation Pattern

VS Code Server requires authentication via token, then navigation to workspace:

```typescript
// Step 1: Authenticate
await page.goto(`${BASE_URL}/?tkn=${token}`, { waitUntil: 'domcontentloaded', timeout: 10_000 });
// Step 2: Navigate to workspace
await page.goto(`${BASE_URL}/?folder=${encodeURIComponent(FOLDER)}`, { waitUntil: 'domcontentloaded', timeout: 15_000 });
```

Do NOT try to do both in a single URL — the reference suite uses this two-step approach.

---

## 8. Next Steps (Priority Order)

1. **Fix the dialog dismissal** — Add Escape key press to dismiss the "Get Started" modal in `waitForVSCode()`
2. **Re-run tests** — All 12 should pass after the dialog fix
3. **Commit the test fixes** — Add tests to the branch
4. **Manual verification** — Open `https://<host>:8560/?tkn=<token>&folder=/workspace` in a browser and confirm:
   - VS Code loads without errors
   - Terminal works (Ctrl+`, type commands)
   - File explorer shows workspace files
   - Secret storage cookies are set (check DevTools → Application → Cookies)
   - Extensions can be installed
5. **Report findings** — If all works, the workarounds can be removed (not just commented out)

---

## 9. Key Files

| File | Purpose |
|------|---------|
| `Dockerfile` | Modified — 3 workarounds commented out |
| `scripts/launcher-dev.sh` | New — isolated dev launcher |
| `scripts/launcher.sh` | Unchanged — production launcher |
| `scripts/mint-proxy.js` | Unchanged — just not COPYed in dev |
| `config/vscode-settings.json` | Unchanged — just not COPYed in dev |
| `tests/playwright.config.ts` | New — Playwright config |
| `tests/vscode-web.spec.ts` | New — E2E tests (6/12 passing) |
| `package.json` | New — npm init with `@playwright/test` |
| `tests/report/` | Playwright HTML report |
| `test-results/` | Failure screenshots + traces |

---

## 10. Quick Reference Commands

```bash
# Build dev image
./scripts/launcher-dev.sh build

# Create/destroy sessions
./scripts/launcher-dev.sh create 1 /tmp/vscode-dev-workspace
./scripts/launcher-dev.sh stop 1
./scripts/launcher-dev.sh purge 1

# Run tests
npx playwright test --config tests/playwright.config.ts --project=chromium

# View test report
npx playwright show-report tests/report

# View failure trace
npx playwright show-trace test-results/<folder>/trace.zip

# Check container logs
podman logs vscode-dev-1

# Get access URL
./scripts/launcher-dev.sh token 1
```
