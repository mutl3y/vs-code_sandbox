# VS Code Server in Container

Microsoft VS Code Server running in Podman containers, accessible via browser over HTTPS with connection-token authentication and mint-proxy encryption. Up to 3 parallel isolated sessions, each with a persistent workspace, extensions, and secret storage.

## Status

✅ HTTPS + WebSocket fully working  
✅ Connection-token auth  
✅ Extensions persist across container removal  
✅ Stable token URL across restarts  
✅ Workspace trust dialogs suppressed  
✅ Podman compatible  
✅ Mint-proxy for ServerKeyedAESCrypto secret encryption  
✅ GitHub CLI auth integration  

## Quick Start

```bash
# 1. One-time: create your local CA (skip if already done)
bash ca/create-ca.sh

# 2. One-time: generate server cert (auto-detects host IP)
bash ca/gen-cert.sh ca/ vscode-server

# 3. One-time: import ca/ca-cert.pem into your browser as a trusted CA

# 4. Build the image
./scripts/launcher.sh build

# 5. Create a session
./scripts/launcher.sh create 1 /path/to/workspace
# → prints: https://192.168.x.x:8550/?tkn=<token>&folder=/workspace
```

> **New here?** Read the [beginner-friendly step-by-step guide](docs/GUIDE.md).

## Session Commands

```bash
./scripts/launcher.sh list              # all running sessions + URLs
./scripts/launcher.sh token 1           # URL for session 1
./scripts/launcher.sh stop 1            # stop (volumes kept)
./scripts/launcher.sh remove 1          # remove container (volumes kept)
./scripts/launcher.sh purge 1           # remove container + all volumes
```

## Ports

| Session | HTTPS | HTTP redirect | Internal VS Code | Mint-Proxy |
|---------|-------|--------------|-----------------|------------|
| 1       | 8550  | 8440          | 9200            | 9300       |
| 2       | 8551  | 8441          | 9201            | 9301       |
| 3       | 8552  | 8442          | 9202            | 9302       |

## Architecture

```text
Browser (HTTPS :8550–8552)
  ↓  nginx TLS termination  --network=host
mint-proxy (127.0.0.1:9300–9302, ServerKeyedAESCrypto key-minting)
  ↓
VS Code Server (127.0.0.1:9200–9202, loopback only)
```

Single image: `vscode-agent:default`  
Base: `mcr.microsoft.com/vscode/devcontainers/base:ubuntu-22.04` (Microsoft official)

## Persistence

| What               | Volume                                          | Removed by         |
|--------------------|------------------------------------------------|-------------------|
| Extensions         | `vscode-ssl-v2-extensions-N` (per session)     | `purge`           |
| VS Code data/state | `vscode-ssl-v2-server-data-N` (per session)    | `purge`           |
| Config (.config)   | `vscode-ssl-v2-config-N` (per session)         | `purge`           |
| Connection token   | `vscode-ssl-v2-token-shared` (all sessions)    | manual only       |
| Workspace files    | host bind-mount                                | never             |

## Repository Layout

```text
├── Dockerfile                   — Single-image build (Microsoft official + mint-proxy)
├── _deprecated/                 — Archived old Dockerfiles and stale files
├── config/
│   └── vscode-settings.json     — VS Code settings template (copied on first boot)
├── ca/
│   ├── create-ca.sh             — bootstrap CA (run once per machine)
│   ├── gen-cert.sh              — generate server cert (run once per machine)
│   ├── ca-cert.pem              — CA public cert (import into browser)
│   # ca-key.pem, server.key, server.crt are gitignored
├── scripts/
│   ├── launcher.sh              — session management CLI
│   └── mint-proxy.js            — Node.js proxy for secret key-minting
├── docker-compose.yml           — Alternative compose-based session config
└── docs/
    ├── GUIDE.md                 — Step-by-step beginner guide
    ├── ARCHITECTURE.md          — Topology, volumes, startup sequence
    ├── HTTPS_SETUP.md           — CA setup, cert generation, browser trust
    └── DESIGN_DECISIONS.md      — Rationale for major decisions
```

## Documentation

- **[GUIDE.md](docs/GUIDE.md)** — start here, beginner-friendly step-by-step guide
- **[HTTPS_SETUP.md](docs/HTTPS_SETUP.md)** — CA, certs, browser trust
- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)** — topology, volumes, mint-proxy, auth flow
- **[DESIGN_DECISIONS.md](docs/DESIGN_DECISIONS.md)** — rationale for major decisions
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
