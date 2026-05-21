# HTTPS Setup Guide

## Status

✅ Fully working — HTTPS + WebSocket + connection-token auth + mint-proxy secret encryption + persistent extensions

## Architecture

```
Browser (HTTPS)
    ↓ TLS on port 8550-8552
nginx (reverse proxy, TLS termination)
    ↓ HTTP on 127.0.0.1:9300-9302 (loopback only)
mint-proxy (ServerKeyedAESCrypto key-minting + cookies)
    ↓ HTTP on 127.0.0.1:9200-9202 (loopback only)
VS Code Server (microsoft server-linux-x64-web)
```

**Image**: `vscode-agent:default` (single image, Microsoft official base)
**Base binary**: `server-linux-x64-web` from `update.code.visualstudio.com`
**Auth**: Connection token (random 32-byte hex) passed as `?tkn=` URL param, validated by VS Code, stored in a session cookie
**Secrets**: ServerKeyedAESCrypto via mint-proxy (persistent across page refreshes)

## Quick Setup

### 1. Bootstrap Your CA (once per machine)

```bash
bash ca/create-ca.sh
```

Creates `ca/ca-cert.pem` (public, import into browser) and `ca/ca-key.pem` (private, gitignored).

### 2. Generate Server Certificate

```bash
bash ca/gen-cert.sh ca/ vscode-server
```

Generates `ca/server.crt` + `ca/server.key` signed by your CA. Host LAN IP is detected automatically and added to the SAN.

### 3. Trust the CA in Your Browser (once)

**Chrome / Edge:**
Settings → Privacy and security → Security → Manage certificates → Authorities → Import `ca/ca-cert.pem`

**Firefox:**
Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import `ca/ca-cert.pem`

**Linux system-wide:**
```bash
sudo cp ca/ca-cert.pem /usr/local/share/ca-certificates/vscode-container-ca.crt
sudo update-ca-certificates
```

### 4. Build the Image

```bash
./scripts/launcher.sh build
```

Builds `vscode-agent:default` (also tagged as `stable`, `ssl-v2`, `latest`).

### 5. Create a Session

```bash
./scripts/launcher.sh create 1 /path/to/workspace
```

Output shows the full access URL with token:
```
https://192.168.x.x:8550/?tkn=<token>&folder=/workspace
```

## Ports

| Session | HTTPS Port | HTTP Redirect | Mint-Proxy Port | Internal VS Code Port |
|---------|-----------|--------------|----------------|---------------------|
| 1       | 8550      | 8440          | 9300           | 9200                 |
| 2       | 8551      | 8441          | 9301           | 9201                 |
| 3       | 8552      | 8442          | 9302           | 9202                 |

## Persistence (Named Volumes)

| Volume | Contents | Survives |
|--------|----------|---------|
| `vscode-ssl-v2-extensions-N` | Installed extensions (per session) | `purge` |
| `vscode-ssl-v2-server-data-N` | VS Code data, state, secrets (per session) | `purge` |
| `vscode-ssl-v2-config-N` | .config dir (per session) | `purge` |
| `vscode-ssl-v2-token-shared` | Connection token (shared across all sessions) | manual only |

The shared token volume means all sessions use the same `?tkn=` value — only the port differs.

## Networking: Why `--network=host`

Podman's default pasta networking mode breaks WebSocket connections to VS Code. Using `--network=host` binds the container directly to the host network stack. nginx listens on the host SSL port and proxies to loopback.

## WebSocket: Why `$http_host` Not `$host`

nginx's `$host` variable strips the port number from the Host header. VS Code Server uses the Host header to construct WebSocket URLs, so it would attempt `wss://hostname/` (defaulting to port 443) instead of `wss://hostname:8550/`, causing **WebSocket Error 1006**.

Fix in the generated nginx config:
```nginx
proxy_set_header Host $http_host;  # preserves :8550
```

## Session Management Commands

```bash
./scripts/launcher.sh build                          # Build image
./scripts/launcher.sh create 1 /path/workspace       # Start session 1
./scripts/launcher.sh create 1 /path /path/certs     # Custom cert dir
./scripts/launcher.sh list                           # Show all sessions + URLs
./scripts/launcher.sh token 1                        # Print URL for session 1
./scripts/launcher.sh stop 1                         # Stop session 1
./scripts/launcher.sh remove 1                       # Remove container (volumes kept)
./scripts/launcher.sh purge 1                        # Remove container + all volumes
```

## Workspace Trust

Workspace trust dialogs are suppressed by settings baked into the image at build time. `config/vscode-settings.json` is copied to both Machine and User settings scopes on first container boot. No manual steps needed.

## What Is and Isn't in Git

Gitignored (never committed):
- `ca/ca-key.pem` — CA private key
- `ca/server.key` — server private key
- `ca/server.crt` — server cert (IP-specific, regenerate per machine)
- `ca/*.srl`, `ca/*.csr` — signing artefacts

Committed (safe, no secrets):
- `ca/create-ca.sh` — CA bootstrap script
- `ca/gen-cert.sh` — server cert generation script
- `ca/ca-cert.pem` — CA public certificate (optional: commit for team distribution)

## Architecture

```
Browser (HTTPS)
    ↓ TLS on port 8540-8542
nginx (reverse proxy, TLS termination)
    ↓ HTTP on 127.0.0.1:9100-9102 (loopback only)
VS Code Server (microsoft server-linux-x64-web)
```

**Image**: `vscode-agent:ssl` (layers on `vscode-agent:latest`)  
**Base binary**: `server-linux-x64-web` from `update.code.visualstudio.com`  
**Auth**: Connection token (random 32-byte hex) passed as `?tkn=` URL param, validated by VS Code, stored in a session cookie

## Quick Setup

### 1. Bootstrap Your CA (once per machine)

```bash
bash ca/create-ca.sh
```

Creates `ca/ca-cert.pem` (public, import into browser) and `ca/ca-key.pem` (private, gitignored).

### 2. Generate Server Certificate

```bash
bash ca/gen-cert.sh ca/ vscode-server
```

Generates `ca/server.crt` + `ca/server.key` signed by your CA. Host LAN IP is detected automatically and added to the SAN.

### 3. Trust the CA in Your Browser (once)

**Chrome / Edge:**  
Settings → Privacy and security → Security → Manage certificates → Authorities → Import `ca/ca-cert.pem`

**Firefox:**  
Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import `ca/ca-cert.pem`

**Linux system-wide:**
```bash
sudo cp ca/ca-cert.pem /usr/local/share/ca-certificates/vscode-container-ca.crt
sudo update-ca-certificates
```

### 4. Build the SSL Image

```bash
./scripts/launcher.sh ssl-build
```

### 5. Create a Session

```bash
./scripts/launcher.sh ssl-create 1 /path/to/workspace
```

Output shows the full access URL with token:
```
https://192.168.x.x:8540/?tkn=<token>&folder=/workspace
```

## Ports

| Session | HTTPS Port | Internal VS Code Port |
|---------|-----------|----------------------|
| 1       | 8540      | 9100                 |
| 2       | 8541      | 9101                 |
| 3       | 8542      | 9102                 |

## Persistence (Named Volumes)

| Volume | Contents | Survives |
|--------|----------|---------|
| `vscode-ssl-extensions-N` | Installed extensions | `ssl-remove` |
| `vscode-ssl-token-shared` | Connection token (shared across all sessions) | `ssl-remove` |

The shared token volume means all sessions use the same `?tkn=` value — only the port differs.

## Networking: Why `--network=host`

Podman's default pasta networking mode breaks WebSocket connections to VS Code. Using `--network=host` binds the container directly to the host network stack. nginx listens on the host SSL port and proxies to VS Code on loopback.

## WebSocket: Why `$http_host` Not `$host`

nginx's `$host` variable strips the port number from the Host header. VS Code Server uses the Host header to construct WebSocket URLs, so it would attempt `wss://hostname/` (defaulting to port 443) instead of `wss://hostname:8540/`, causing **WebSocket Error 1006**.

Fix in the generated nginx config:
```nginx
proxy_set_header Host $http_host;  # preserves :8540
```

## Session Management Commands

```bash
./scripts/launcher.sh ssl-build                              # Build SSL image
./scripts/launcher.sh ssl-create 1 /path/to/workspace       # Create session
./scripts/launcher.sh ssl-create 1 /path/to/workspace /certs # Custom cert dir
./scripts/launcher.sh ssl-list                               # List sessions + URLs
./scripts/launcher.sh ssl-token 1                            # Print URL for session 1
./scripts/launcher.sh ssl-stop 1                             # Stop (volumes preserved)
./scripts/launcher.sh ssl-remove 1                           # Remove container (volumes kept)
./scripts/launcher.sh ssl-purge 1                            # Remove container + volumes
```

## Workspace Trust

Workspace trust dialogs are suppressed by settings baked into the image at build time. `config/vscode-settings.json` is copied to both Machine and User settings scopes in the Dockerfile. No manual steps needed.

## What Is and Isn't in Git

Gitignored (never committed):
- `ca/ca-key.pem` — CA private key
- `ca/server.key` — server private key
- `ca/server.crt` — server cert (IP-specific, regenerate per machine)
- `ca/*.srl`, `ca/*.csr` — signing artefacts

Committed (safe, no secrets):
- `ca/create-ca.sh` — CA bootstrap script
- `ca/gen-cert.sh` — server cert generation script
- `ca/ca-cert.pem` — CA public certificate (optional: commit for team distribution)
