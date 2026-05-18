# VS Code Server in Container

Microsoft VS Code Server running in Podman containers, accessible via browser over HTTPS with connection-token authentication. Up to 3 parallel isolated sessions, each with a persistent workspace, extensions, and a shared connection token.

## Status

✅ HTTPS + WebSocket fully working
✅ Connection-token auth
✅ Extensions persist across container removal
✅ Shared token (stable URL across restarts)
✅ Workspace trust dialogs suppressed
✅ Podman and Docker compatible

## Quick Start (SSL)

```bash
# 1. One-time: create your local CA
bash ca/create-ca.sh

# 2. One-time: generate server cert (auto-detects host IP)
bash ca/gen-cert.sh ca/ vscode-server

# 3. One-time: import ca/ca-cert.pem into your browser as a trusted CA

# 4. Build images
./scripts/launcher.sh ssl-build

# 5. Create a session
./scripts/launcher.sh ssl-create 1 /path/to/workspace
# → prints: https://192.168.x.x:8540/?tkn=<token>&folder=/workspace
```

## Session Commands

```bash
./scripts/launcher.sh ssl-list          # all running sessions + URLs
./scripts/launcher.sh ssl-token 1       # URL for session 1
./scripts/launcher.sh ssl-stop 1        # stop (volumes kept)
./scripts/launcher.sh ssl-remove 1      # remove container (extensions + token survive)
./scripts/launcher.sh ssl-purge 1       # remove container + volumes
```

## Ports

| Session | HTTPS | Internal |
|---------|-------|----------|
| 1       | 8540  | 9100     |
| 2       | 8541  | 9101     |
| 3       | 8542  | 9102     |

## Architecture

```text
Browser (HTTPS :8540–8542)
  ↓  nginx TLS termination  --network=host
VS Code Server (127.0.0.1:9100–9102, loopback only)
```

Two images:

| Image                 | Purpose                        |
|-----------------------|--------------------------------|
| `vscode-agent:latest` | HTTP base (no auth, local use) |
| `vscode-agent:ssl`    | HTTPS + nginx + token auth     |

## Persistence

| What             | Volume                                   | Removed by                  |
|------------------|------------------------------------------|-----------------------------|
| Extensions       | `vscode-ssl-extensions-N` (per session)  | `ssl-purge` only            |
| Connection token | `vscode-ssl-token-shared` (all sessions) | `ssl-purge` on last session |
| Workspace files  | host bind-mount                          | never                       |

## Repository Layout

```text
├── Dockerfile              — HTTP base image (vscode-agent:latest)
├── Dockerfile.ssl          — SSL image layered on base (vscode-agent:ssl)
├── config/
│   └── vscode-settings.json — workspace trust settings (baked in at build)
├── ca/
│   ├── create-ca.sh        — bootstrap CA (run once per machine)
│   ├── gen-cert.sh         — generate server cert (run once per machine)
│   └── ca-cert.pem         — CA public cert (import into browser)
│   # ca-key.pem, server.key, server.crt are gitignored
├── scripts/
│   └── launcher.sh         — session management CLI
├── docker-compose.yml      — HTTP sessions (3 pre-configured)
└── docs/
    ├── GUIDE.md            — full command reference + onboarding
    ├── ARCHITECTURE.md     — topology, volumes, startup sequence
    ├── HTTPS_SETUP.md      — CA setup, cert generation, browser trust
    └── DESIGN_DECISIONS.md — rationale for every major decision
```

## Documentation

- **[GUIDE.md](docs/GUIDE.md)** — start here for setup and all commands
- **[HTTPS_SETUP.md](docs/HTTPS_SETUP.md)** — CA, certs, browser trust
- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)** — topology, volumes, auth flow
- **[DESIGN_DECISIONS.md](docs/DESIGN_DECISIONS.md)** — technical rationale

## Cloning on a New Machine

```bash
bash ca/create-ca.sh                    # create your own CA
bash ca/gen-cert.sh ca/ vscode-server   # cert for your machine's IP
# import ca/ca-cert.pem into browser
./scripts/launcher.sh ssl-build
./scripts/launcher.sh ssl-create 1 /path/to/workspace
```

No private keys are committed. Each machine generates its own.
