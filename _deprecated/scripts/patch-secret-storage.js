#!/usr/bin/env node
/**
 * patch-secret-storage.js
 *
 * Patches the compiled VS Code Server to implement server-side secret storage
 * key minting (mirrors the CLI's implementation in cli/src/commands/serve_web.rs).
 *
 * Changes:
 *  1. webClientServer.js — adds the /_vscode-server/mint-key endpoint, sets
 *     vscode-secret-key-path + vscode-cli-secret-half cookies so the browser
 *     workbench uses ServerKeyedAESCrypto (encrypted localStorage) instead of
 *     falling back to in-memory storage.
 *
 *  2. workbench.js — removes the remoteAuthority + cookie check so
 *     LocalStorageSecretStorageProvider is always used (the cookies are now
 *     always present thanks to change #1).
 *
 * Usage:
 *   node patch-secret-storage.js <vscode-install-dir>
 *   e.g. node patch-secret-storage.js /usr/local/lib/vscode-server-linux-x64-web
 */

'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const installDir = process.argv[2];
if (!installDir) {
  console.error('Usage: node patch-secret-storage.js <vscode-install-dir>');
  process.exit(1);
}

// ---------------------------------------------------------------------------
// Patch 1: workbench.js  — remove the in-memory fallback condition
// ---------------------------------------------------------------------------
const workbenchPath = path.join(installDir, 'out/vs/code/browser/workbench/workbench.js');
let wb = fs.readFileSync(workbenchPath, 'utf8');

// Pattern that sets secretStorageProvider to undefined when no cookie present:
//   secretStorageProvider:e.remoteAuthority&&!t?void 0:new XYZ(o)
// We want:
//   secretStorageProvider:new XYZ(o)
const WB_PATTERN = /secretStorageProvider:[a-zA-Z_$][\w$]*\.remoteAuthority&&![a-zA-Z_$][\w$]*\?void 0:(new [a-zA-Z_$][\w$]*\([a-zA-Z_$][\w$]*\))/;
if (!WB_PATTERN.test(wb)) {
  // Already patched or pattern changed — try the already-patched form and skip
  if (/secretStorageProvider:new [a-zA-Z_$][\w$]*\(/.test(wb)) {
    console.log('workbench.js: already patched, skipping');
  } else {
    console.error('workbench.js: pattern not found — file may have changed');
    process.exit(1);
  }
} else {
  wb = wb.replace(WB_PATTERN, 'secretStorageProvider:$1');
  fs.writeFileSync(workbenchPath, wb);
  console.log('✓ workbench.js patched (removed in-memory fallback)');
}

// ---------------------------------------------------------------------------
// Patch 2: webClientServer.js — inject mint endpoint + secret cookies
// ---------------------------------------------------------------------------
const serverPath = path.join(installDir, 'out/vs/server/node/webClientServer.js');
let sv = fs.readFileSync(serverPath, 'utf8');

const MINT_MARKER = '/*__secret-storage-patch__*/';
if (sv.includes(MINT_MARKER)) {
  console.log('webClientServer.js: already patched, skipping');
  process.exit(0);
}

// ---------------------------------------------------------------------------
// The injected code block (will be prepended to the file as an IIFE that
// monkey-patches WebClientServer.prototype.handle).
// ---------------------------------------------------------------------------
const INJECTION = `
${MINT_MARKER}
(function patchSecretStorage(){
  const _crypto = require('crypto');
  const _cookie = require('cookie'); // already required by webClientServer

  const MINT_PATH       = '/_vscode-server/mint-key';
  const PATH_COOKIE     = 'vscode-secret-key-path';
  const CLIENT_COOKIE   = 'vscode-cli-secret-half';
  const KEY_BYTES       = 32;

  // Per-process server secret (regenerated on restart, intentional).
  const SERVER_SECRET = _crypto.randomBytes(KEY_BYTES);

  function getOrCreateClientKeyHalf(cookies) {
    try {
      const raw = Buffer.from(cookies[CLIENT_COOKIE] || '', 'base64url');
      if (raw.byteLength === KEY_BYTES) { return raw; }
    } catch(_) {}
    return _crypto.randomBytes(KEY_BYTES);
  }

  function buildSecretCookies(clientHalf, mintPath) {
    return [
      \`\${PATH_COOKIE}=\${mintPath}; SameSite=Strict; Path=/\`,
      \`\${CLIENT_COOKIE}=\${clientHalf.toString('base64url')}; SameSite=Strict; HttpOnly; Max-Age=2592000; Path=/\`
    ];
  }

  // Find WebClientServer class — it is exported and has a 'handle' method.
  const mod = module; // capture webClientServer module
  const origLoad = Module._load;
  // Patch by hooking the exports after the module finishes loading:
  // We use a simpler approach — defer until after exports are populated.
  setImmediate(function applyPatch() {
    // Walk all loaded modules looking for WebClientServer
    const cache = require.cache;
    for (const id of Object.keys(cache)) {
      if (!id.includes('webClientServer')) { continue; }
      const m = cache[id];
      if (!m || !m.exports) { continue; }
      for (const key of Object.keys(m.exports)) {
        const Cls = m.exports[key];
        if (typeof Cls !== 'function' || !Cls.prototype || !Cls.prototype.handle) { continue; }

        const _origHandle = Cls.prototype.handle;
        Cls.prototype.handle = async function patchedHandle(req, res, parsedUrl, pathname) {
          // Route mint endpoint
          if (pathname === MINT_PATH) {
            const cookies = _cookie.parse(req.headers.cookie || '');
            const clientHalf = getOrCreateClientKeyHalf(cookies);
            const serverPart = _crypto.createHash('sha256')
              .update(SERVER_SECRET)
              .update(clientHalf)
              .digest()
              .slice(0, KEY_BYTES);
            res.writeHead(200, {
              'Content-Type': 'application/octet-stream',
              'Cache-Control': 'no-store'
            });
            return void res.end(serverPart);
          }
          return _origHandle.apply(this, arguments);
        };

        // Also patch _handleRoot to set secret cookies
        const _origRoot = Cls.prototype._handleRoot;
        if (_origRoot) {
          Cls.prototype._handleRoot = async function patchedHandleRoot(req, res, parsedUrl) {
            // Intercept res.writeHead to inject secret cookies
            const _origWriteHead = res.writeHead.bind(res);
            res.writeHead = function(statusCode, headers) {
              const basePath = (Array.isArray(req.headers['x-forwarded-prefix'])
                ? req.headers['x-forwarded-prefix'][0]
                : req.headers['x-forwarded-prefix']) || '/';
              const mintPath = (basePath + MINT_PATH).replace('//', '/');
              const cookies = _cookie.parse(req.headers.cookie || '');
              const clientHalf = getOrCreateClientKeyHalf(cookies);
              const secretCookies = buildSecretCookies(clientHalf, mintPath);
              if (headers && typeof headers === 'object') {
                const existing = headers['Set-Cookie'];
                if (Array.isArray(existing)) {
                  headers['Set-Cookie'] = [...existing, ...secretCookies];
                } else if (existing) {
                  headers['Set-Cookie'] = [existing, ...secretCookies];
                } else {
                  headers['Set-Cookie'] = secretCookies;
                }
              }
              return _origWriteHead(statusCode, headers);
            };
            return _origRoot.apply(this, arguments);
          };
        }

        console.log('[secret-storage-patch] WebClientServer patched successfully');
        return;
      }
    }
    // If we get here the cache walk didn't find it yet — retry once more
    console.error('[secret-storage-patch] WARNING: WebClientServer not found in module cache');
  });
})();
`;

// Prepend the injection to the file
fs.writeFileSync(serverPath, INJECTION + '\n' + sv);
console.log('✓ webClientServer.js patched (mint endpoint + secret cookies)');
