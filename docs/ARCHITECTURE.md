# VS Code Container Architecture

## Overview

Microsoft VS Code Server (`server-linux-x64-web`) running in Podman containers, accessible via browser over HTTPS with connection-token authentication and mint-proxy secret encryption.

Single image: `vscode-agent:default`  
Base: `mcr.microsoft.com/vscode/devcontainers/base:ubuntu-22.04` (Microsoft official)

## Container Topology

```
Browser
  │  HTTPS (port 8550/8551/8552)
  ▼
nginx (TLS termination, --network=host)
  │  HTTP (127.0.0.1:9300/9301/9302, loopback only)
  ▼
mint-proxy (ServerKeyedAESCrypto key-minting + cookie management)
  │  HTTP (127.0.0.1:9200/9201/9202, loopback only)
  ▼
VS Code Server (server-linux-x64-web)
  │
  ├── /workspace             ← host path bind-mount (project files)
  ├── extensions vol         ← vscode-ssl-v2-extensions-N
  ├── server data vol        ← vscode-ssl-v2-server-data-N
  ├── config vol             ← vscode-ssl-v2-config-N
  └── token store vol        ← vscode-ssl-v2-token-shared
```

Each session is an independent container. Three sessions maximum (ports 8550–8552).

## Port Map

| Session | HTTPS (nginx) | HTTP redirect | Proxy (mint-proxy) | VS Code (internal) |
|---------|--------------|--------------|--------------------|-----------------|
| 1       | 8550         | 8440          | 9300               | 9200               |
| 2       | 8551         | 8441          | 9301               | 9201               |
| 3       | 8552         | 8442          | 9302               | 9202               |

## Image Build Layers

```
mcr.microsoft.com/vscode/devcontainers/base:ubuntu-22.04
  └── vscode-agent:default  (Dockerfile — single stage)
        ├── System deps: git, curl, gnupg, nginx, ca-certificates
        ├── Secret storage: libsecret, gnome-keyring, dbus, dbus-x11
        ├── GitHub CLI (GPG-verified install from cli.github.com)
        ├── Node.js 22.x (from NodeSource)
        ├── /workspace directory + permissions
        ├── /opt/vscode-defaults/settings.json (from config/)
        ├── /opt/mint-proxy.js (from scripts/)
        ├── /opt/init/startup.sh (embedded via COPY heredoc)
        └── VS Code Server binary (server-linux-x64-web, downloaded at build time)
```

Also tagged as: `vscode-agent:stable`, `vscode-agent:ssl-v2`, `vscode-agent:latest`

## Mint-Proxy: What and Why

VS Code's `ServerKeyedAESCrypto` secret storage requires a server-side key-minting endpoint at `POST /_vscode-server/mint-key`. Without it, extensions cannot persist secrets (GitHub tokens, API keys) across browser sessions.

`mint-proxy.js` is a lightweight Node.js HTTP proxy that:
1. Intercepts `POST /_vscode-server/mint-key` requests
2. Returns the server-side AES key half
3. Sets `vscode-secret-key-path` and `vscode-cli-secret-half` cookies
4. Forwards all other requests to VS Code unchanged

Without mint-proxy, secrets are stored in-memory only and lost on page refresh.

## Volumes

| Volume | Path in container | Scope | Survives |
|--------|------------------|-------|---------|
| `vscode-ssl-v2-extensions-N` | `/home/vscode/.vscode-server/extensions` | Per session | `purge` |
| `vscode-ssl-v2-server-data-N` | `/home/vscode/.vscode-server/data` | Per session | `purge` |
| `vscode-ssl-v2-config-N` | `/home/vscode/.config` | Per session | `purge` |
| `vscode-ssl-v2-token-shared` | `/home/vscode/.token-store` | Shared (all sessions) | manual only |
| bind: workspace path | `/workspace` | Per session | Always (host dir) |
| bind: `~/.config/gh` | `/home/vscode/.config/gh-host` | Read-only | Always |

The shared token volume means all sessions use the same `?tkn=` value — only the port differs.

## Startup Sequence

```
1.  Container starts → /opt/init/startup.sh (runs as root)
2.  Fix ownership of volume mounts → chown vscode:vscode
3.  First-run init: copy settings.json to DATA_DIR if not present
4.  Git credential config (if .git-credentials mounted)
5.  GitHub CLI auth setup (if gh-host volume mounted)
6.  D-Bus init → dbus-daemon --system + dbus-launch
7.  gnome-keyring unlock (background)
8.  Connection token:
      /home/vscode/.token-store/connection-token exists? → reuse
      missing? → openssl rand -hex 32 → write to store
9.  Write token to /home/vscode/.vscode-token
10. Stable machine ID:
      read /home/vscode/.vscode-server/data/stable-machine-id
      (ensures encrypted secrets survive container rebuilds)
11. Write /etc/machine-id from stable ID
12. Generate /etc/nginx/conf.d/vscode.conf (TLS on SSL_PORT, proxy to PROXY_PORT, /clear-cache endpoint)
13. Start mint-proxy:  node /opt/mint-proxy.js (PROXY_PORT → VSCODE_PORT)
14. Start nginx:       nginx -g "daemon off;" (SSL_PORT → PROXY_PORT)
15. Start VS Code:     VSCodeRestart() loop — restarts on crash, only bails if nginx/mint-proxy dies
16. Print access URLs (including /clear-cache for IndexedDB wipe)
17. wait -n: shut down all three if any one exits
```

## Authentication Flow

```
User navigates to https://<host>:8550/?tkn=<token>&folder=/workspace
    ↓
nginx (TLS) → mint-proxy
    ↓
mint-proxy forwards to VS Code + sets secret cookies on first mint-key response
    ↓
VS Code validates token → sets auth cookie → 302 → /
    ↓
All subsequent requests use cookie (no token in URL after first load)
    ↓
Extension secrets use ServerKeyedAESCrypto (via mint-proxy cookies) → persisted in gnome-keyring
```

## Networking: Why `--network=host`

Podman's default pasta networking breaks WebSocket connections to VS Code. Using `--network=host` binds the container directly to the host network stack. nginx listens on the host SSL port and proxies to mint-proxy on loopback.

## WebSocket: Why `$http_host` Not `$host`

nginx's `$host` strips the port from the Host header. VS Code uses Host to build WebSocket URLs — without the port it would try `wss://hostname/` (port 443) instead of `wss://hostname:8550/`, causing **WebSocket Error 1006**.

Fix in generated nginx config:
```nginx
proxy_set_header Host $http_host;  # preserves :8550
```

## Networking

`--network=host` is required. Podman's default pasta userspace networking breaks WebSocket connections between the browser and VS Code. With host networking:

- nginx binds directly on the host at port 8540–8542
- VS Code Server binds on 127.0.0.1:9100–9102 (loopback, unexposed)
- Browser WebSocket traffic flows through nginx with correct headers

Critical nginx proxy header:

```nginx
proxy_set_header Host $http_host;   # preserves port number
# NOT $host — that strips the port, breaking VS Code WebSocket URL construction
```

## Crash Recovery (VSCodeRestart Loop)

VS Code Server can crash with `ECONNRESET` when the browser drops a connection mid-operation (e.g. adding workspace folders). Previously this killed the entire container via `wait -n`.

The `VSCodeRestart()` function in the startup script handles this:

1. Runs VS Code in a `while true` loop
2. On crash: logs the exit code, waits 2 seconds, restarts VS Code
3. On each iteration: checks if nginx and mint-proxy are still alive
4. Only exits the loop (and shuts down the container) if nginx or mint-proxy dies

This means transient VS Code crashes (like ECONNRESET) are automatically recovered from without losing the session.

## /clear-cache Endpoint

VS Code Web stores provider metadata (model providers, extensions, settings) in the browser's IndexedDB (`vscode-web-db` → `vscode-userdata-store`). Stale entries can persist across container rebuilds because they live in the browser, not the server.

The `/clear-cache` nginx endpoint serves an HTML page that:
1. Enumerates all IndexedDB databases via `indexedDB.databases()`
2. Deletes each one via `indexedDB.deleteDatabase(name)`
3. Redirects to VS Code with the connection token

Usage: `https://<host>:<port>/clear-cache`

This is useful when:
- Stale OpenRouter/custom provider registrations appear
- After container rebuilds with different tokens
- When extensions fail to initialize due to corrupted state

## Workspace Permissions: `--userns=keep-id`

Rootless Podman runs containers in a user namespace where UIDs are remapped:

| Location                          | UID                                  |
|-----------------------------------|--------------------------------------|
| Host user (`mark`)                | 1000                                 |
| Container `root`                  | → host uid 1000 (your user)          |
| Container `vscode` (uid=1000)     | → host subordinate UID (~100001)     |

This means bind-mounted workspace files — owned by uid=1000 on the host — appear **root-owned** inside the container. The `vscode` process (mapped to a sub-uid) cannot write to them.

`--userns=keep-id` fixes this by keeping the calling user's UID identical inside the container:

| Location                          | UID                                  |
|-----------------------------------|--------------------------------------|
| Host user (`mark`)                | 1000                                 |
| Container `vscode` (uid=1000)     | → host uid 1000 ✓                    |

All `ssl-create` sessions use this flag. On first use, Podman creates an ID-mapped copy of the image layers — a one-time operation per image.

## CA and Certificate Infrastructure

```text
ca/
  create-ca.sh       → generates ca-cert.pem + ca-key.pem (run once)
  gen-cert.sh        → generates server.crt + server.key (run per machine)
  ca-cert.pem        → CA public cert (import into browser trust store)
  ca-key.pem         → CA private key (gitignored)
  server.crt         → server cert with SAN for localhost + host LAN IP (gitignored)
  server.key         → server private key (gitignored)
```

Certs are bind-mounted at `podman run` time:

```text
ca/server.crt → /etc/nginx/ssl/server.crt (read-only)
ca/server.key → /etc/nginx/ssl/server.key (read-only)
```

Never baked into the image (no private keys in image layers).

## Multi-Session Coordination

Sessions are completely independent containers. The only shared resource is the connection token volume, allowing a single bookmark to access any session by changing the port number.

```text
Session 1: https://<host>:8540/?tkn=<same-token>&folder=/workspace
Session 2: https://<host>:8541/?tkn=<same-token>&folder=/workspace
Session 3: https://<host>:8542/?tkn=<same-token>&folder=/workspace
```
