# VS Code Container Architecture

## Overview

Microsoft VS Code Server (`server-linux-x64-web`) running in Podman containers, accessible via browser over HTTPS with connection-token authentication.

Two image variants:

| Image | Purpose | Auth | Port range |
|-------|---------|------|-----------|
| `vscode-agent:latest` | HTTP base, no auth | None | 8443–8445 |
| `vscode-agent:ssl` | HTTPS via nginx + token auth | Connection token | 8540–8542 |

## Container Topology (SSL Sessions)

```
Browser
  │  HTTPS (port 8540/8541/8542)
  ▼
nginx (TLS termination, --network=host)
  │  HTTP (127.0.0.1:9100/9101/9102, loopback only)
  ▼
VS Code Server (server-linux-x64-web)
  │
  ├── /workspace        ← host path bind-mount (project files)
  ├── extensions vol    ← named volume (vscode-ssl-extensions-N)
  └── token vol         ← named volume (vscode-ssl-token-shared)
```

Each SSL session is an independent container. Three sessions maximum (ports 8540–8542).

## Image Layers

```
mcr.microsoft.com/vscode/devcontainers/base:ubuntu-22.04
  └── vscode-agent:latest  (Dockerfile)
        ├── System deps: git, python3, nodejs, curl, openssl
        ├── VS Code Server binary (server-linux-x64-web, Microsoft official)
        ├── vscode user (uid=1000, non-root)
        ├── Workspace trust settings baked in (config/vscode-settings.json)
        └── Startup script: /opt/init/startup.sh

        └── vscode-agent:ssl  (Dockerfile.ssl)
              ├── nginx (TLS termination)
              ├── Startup script: /opt/init/startup-ssl.sh
              │     ├── Fix volume ownership (extensions + token dirs)
              │     ├── Reuse or generate connection token
              │     ├── Generate nginx config with $http_host
              │     ├── Start nginx (daemon off)
              │     └── Start VS Code Server on loopback
              └── EXPOSE 8444 (default; overridden by SSL_PORT env var)
```

## Volumes

### SSL Sessions

| Volume | Path in container | Scope | Survives |
|--------|------------------|-------|---------|
| `vscode-ssl-extensions-N` | `/home/vscode/.vscode-server/extensions` | Per session | `ssl-remove` |
| `vscode-ssl-token-shared` | `/home/vscode/.token-store` | Shared (all sessions) | `ssl-remove` |
| bind: workspace path | `/workspace` | Per session | Always (host dir) |

Extensions are per-session (each session can have a different set). The connection token is shared so all sessions use the same `?tkn=` URL parameter.

### HTTP Sessions (docker-compose)

| Volume | Path in container | Purpose |
|--------|------------------|---------|
| bind: workspace path | `/workspace` | Project files |
| bind: worktrees path | `/worktrees` | Git worktrees |

## Startup Sequence (SSL)

```
1.  Container starts → /opt/init/startup-ssl.sh
2.  chown extensions volume → vscode:vscode
3.  chown token store → vscode:vscode
4.  Check /home/vscode/.token-store/connection-token
       exists → reuse token (stable URL across restarts)
       missing → generate new token, write to store
5.  Write token to /home/vscode/.vscode-token
6.  Generate /etc/nginx/conf.d/vscode.conf with SSL_PORT + VSCODE_PORT
7.  Start nginx (daemon off)
8.  su - vscode → start VS Code Server on 127.0.0.1:VSCODE_PORT
9.  Print access URL to container log
10. wait -n: exit if either process dies
```

## Authentication Flow

```
User navigates to https://<host>:8540/?tkn=<token>&folder=/workspace
    ↓
VS Code Server validates token → sets auth cookie → 302 → /
    ↓
All subsequent requests use cookie (no token in URL after first load)
```

Token is 32 bytes of random hex. Stored in `vscode-ssl-token-shared` named volume so it persists across container removal/recreation.

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
