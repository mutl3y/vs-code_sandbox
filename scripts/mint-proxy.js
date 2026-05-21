#!/usr/bin/env node
/**
 * mint-proxy.js — Secret storage key-mint proxy for VS Code Server web
 *
 * Sits between nginx and VS Code Server to implement the same secret-storage
 * key-minting protocol used by the VS Code CLI (cli/src/commands/serve_web.rs).
 *
 * Why: VS Code Server (server-linux-x64-web) never sets the vscode-secret-key-path
 * cookie, so the browser workbench falls back to in-memory secret storage.
 * This proxy sets the two required cookies on every root response and handles
 * the POST /_vscode-server/mint-key endpoint, enabling ServerKeyedAESCrypto so
 * secrets are encrypted and persisted in browser localStorage.
 *
 * Usage:
 *   VSCODE_PORT=8443 PROXY_PORT=8442 node mint-proxy.js
 *
 * Architecture:
 *   nginx (TLS :8540) → this proxy (:8442) → VS Code Server (:8443)
 */

'use strict';

const http      = require('http');
const crypto    = require('crypto');
const { parse } = require('url');

const VSCODE_PORT = parseInt(process.env.VSCODE_PORT  || '8443', 10);
const PROXY_PORT  = parseInt(process.env.PROXY_PORT   || '8442', 10);

const MINT_PATH         = '/_vscode-server/mint-key';
const PATH_COOKIE_NAME  = 'vscode-secret-key-path';
const CLIENT_COOKIE_NAME = 'vscode-cli-secret-half';
const KEY_BYTES         = 32;

// Per-process server secret — regenerated on restart (matches CLI behaviour).
const SERVER_SECRET = crypto.randomBytes(KEY_BYTES);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function parseCookies(cookieHeader) {
  const result = {};
  if (!cookieHeader) { return result; }
  for (const part of cookieHeader.split(';')) {
    const i = part.indexOf('=');
    if (i < 0) { continue; }
    result[part.slice(0, i).trim()] = part.slice(i + 1).trim();
  }
  return result;
}

function getOrCreateClientHalf(cookies) {
  const raw = cookies[CLIENT_COOKIE_NAME];
  if (raw) {
    try {
      const buf = Buffer.from(raw, 'base64url');
      if (buf.byteLength === KEY_BYTES) { return buf; }
    } catch (_) {}
  }
  return crypto.randomBytes(KEY_BYTES);
}

function secretCookieHeaders(clientHalf, mintPath) {
  return [
    `${PATH_COOKIE_NAME}=${mintPath}; SameSite=Strict; Path=/`,
    `${CLIENT_COOKIE_NAME}=${clientHalf.toString('base64url')}; SameSite=Strict; HttpOnly; Max-Age=2592000; Path=/`,
  ];
}

// ---------------------------------------------------------------------------
// Mint endpoint handler
// ---------------------------------------------------------------------------

function handleMint(req, res) {
  const cookies    = parseCookies(req.headers['cookie']);
  const clientHalf = getOrCreateClientHalf(cookies);
  const serverPart = crypto.createHash('sha256')
    .update(SERVER_SECRET)
    .update(clientHalf)
    .digest()
    .slice(0, KEY_BYTES);

  res.writeHead(200, {
    'Content-Type':  'application/octet-stream',
    'Cache-Control': 'no-store',
    'Content-Length': KEY_BYTES,
  });
  res.end(serverPart);
}

// ---------------------------------------------------------------------------
// Transparent proxy with cookie injection on root responses
// ---------------------------------------------------------------------------

function proxyRequest(req, res) {
  const cookies    = parseCookies(req.headers['cookie']);
  const clientHalf = getOrCreateClientHalf(cookies);

  // Determine the mint path using forwarded prefix if set
  const prefix   = (req.headers['x-forwarded-prefix'] || '').replace(/\/$/, '');
  const mintPath = prefix + MINT_PATH;

  const options = {
    hostname: '127.0.0.1',
    port:     VSCODE_PORT,
    path:     req.url,
    method:   req.method,
    headers:  req.headers,  // pass original Host through so VS Code embeds the external port in remoteAuthority
  };

  const proxyReq = http.request(options, (proxyRes) => {
    // Build the combined Set-Cookie list
    const existing    = proxyRes.headers['set-cookie'] || [];
    const extraCookies = secretCookieHeaders(clientHalf, mintPath);
    const allCookies  = [...existing, ...extraCookies];

    const headers = { ...proxyRes.headers, 'set-cookie': allCookies };
    res.writeHead(proxyRes.statusCode, headers);
    proxyRes.pipe(res, { end: true });
  });

  proxyReq.on('error', (err) => {
    console.error('[mint-proxy] upstream error:', err.message);
    if (!res.headersSent) {
      res.writeHead(502);
      res.end('Bad Gateway');
    }
  });

  req.pipe(proxyReq, { end: true });
}

// ---------------------------------------------------------------------------
// Main server
// ---------------------------------------------------------------------------

const server = http.createServer((req, res) => {
  const pathname = parse(req.url || '/').pathname || '/';

  if (pathname === MINT_PATH) {
    return handleMint(req, res);
  }

  // Only inject cookies on root/workbench page responses (status 200 or 302).
  // For all other paths (static assets, websockets via upgrade) proxy normally.
  if (pathname === '/' || pathname === '') {
    return proxyRequest(req, res);
  }

  // Non-root paths: proxy without cookie injection (avoids overhead).
  proxyRequest(req, res);
});

// WebSocket upgrade passthrough
server.on('upgrade', (req, socket, head) => {
  const proxyReq = http.request({
    hostname: '127.0.0.1',
    port:     VSCODE_PORT,
    path:     req.url,
    method:   req.method,
    headers:  req.headers,  // pass original Host through
  });

  proxyReq.on('upgrade', (proxyRes, proxySocket, proxyHead) => {
    socket.write(
      `HTTP/1.1 101 Switching Protocols\r\n` +
      Object.entries(proxyRes.headers).map(([k,v]) => `${k}: ${v}`).join('\r\n') +
      '\r\n\r\n'
    );
    if (proxyHead && proxyHead.length) { proxySocket.write(proxyHead); }
    proxySocket.pipe(socket, { end: true });
    socket.pipe(proxySocket, { end: true });
  });

  proxyReq.on('error', (err) => {
    console.error('[mint-proxy] ws error:', err.message);
    socket.destroy();
  });

  proxyReq.end();

  if (head && head.length) { proxyReq.write(head); }
  proxyReq.end();
});

server.listen(PROXY_PORT, '127.0.0.1', () => {
  console.log(`[mint-proxy] listening on 127.0.0.1:${PROXY_PORT} → VS Code on :${VSCODE_PORT}`);
  console.log(`[mint-proxy] mint endpoint: ${MINT_PATH}`);
});
