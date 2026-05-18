# VS Code Server in Container: Quick Start Guide

## Overview

Run Microsoft VS Code Server in isolated Podman containers, accessible via browser over HTTPS. Supports up to 3 parallel sessions, each with a separate workspace, persistent extensions, and a shared connection token.

Supports both **podman** (recommended) and **docker**.

## Prerequisites

- Podman or Docker installed
- `podman-compose` or `docker-compose`
- `openssl` (for CA and cert generation)

## First-Time Setup (SSL — Recommended)

### 1. Bootstrap your CA

```bash
bash ca/create-ca.sh
```

Generates `ca/ca-cert.pem` (public) and `ca/ca-key.pem` (private, gitignored). Run once per machine.

### 2. Generate a server certificate

```bash
bash ca/gen-cert.sh ca/ vscode-server
```

Detects your host LAN IP automatically and adds it to the certificate SAN. Run once per machine (or after IP change).

### 3. Trust the CA in your browser

Import `ca/ca-cert.pem` into your browser's certificate authority trust store. Required only once per browser.

See [HTTPS_SETUP.md](HTTPS_SETUP.md) for browser-specific instructions.

### 4. Build the SSL image

```bash
./scripts/launcher.sh ssl-build
```

Builds `vscode-agent:ssl` (layered on `vscode-agent:latest`).

### 5. Create a session

```bash
./scripts/launcher.sh ssl-create 1 /path/to/workspace
```

Prints the access URL:
```
https://192.168.x.x:8540/?tkn=<token>&folder=/workspace
```

Open it in the browser. Done.

---

## SSL Session Commands

```bash
# Build images
./scripts/launcher.sh ssl-build                              # Build SSL image (also builds base)

# Create sessions (ports 8540, 8541, 8542)
./scripts/launcher.sh ssl-create 1 /path/to/workspace
./scripts/launcher.sh ssl-create 2 /path/to/other-workspace
./scripts/launcher.sh ssl-create 1 /path/to/workspace /path/to/certs  # custom cert dir

# Inspect
./scripts/launcher.sh ssl-list          # show all running sessions with URLs
./scripts/launcher.sh ssl-token 1       # print access URL for session 1

# Stop / remove
./scripts/launcher.sh ssl-stop 1        # stop container (volumes kept)
./scripts/launcher.sh ssl-remove 1      # remove container (extensions + token survive)
./scripts/launcher.sh ssl-purge 1       # remove container AND its volumes (clean slate)
```

## HTTP Session Commands (no auth, local use only)

```bash
./scripts/launcher.sh build             # Build HTTP base image
./scripts/launcher.sh create 1 /path/to/workspace
./scripts/launcher.sh list
./scripts/launcher.sh stop 1
./scripts/launcher.sh start 1
./scripts/launcher.sh remove 1
./scripts/launcher.sh purge 1
./scripts/launcher.sh logs 1
```

HTTP sessions use ports 8443–8445.

## Ports Reference

| Session | HTTP port | SSL HTTPS port | SSL internal port |
|---------|-----------|---------------|------------------|
| 1       | 8443      | 8540          | 9100             |
| 2       | 8444      | 8541          | 9101             |
| 3       | 8445      | 8542          | 9102             |

## Persistence

Extensions installed via the VS Code extension marketplace survive `ssl-remove` and `ssl-create` cycles. They are stored in a named Podman volume (`vscode-ssl-extensions-N`) that is only deleted by `ssl-purge`.

The connection token is stored in a shared named volume (`vscode-ssl-token-shared`). The token — and therefore your bookmarked URL — persists across container removal and recreation. All sessions share the same token; only the port differs.

## Workspace Trust

Workspace trust dialogs are disabled by default. The setting is baked into the image at build time via `config/vscode-settings.json`. No manual steps required.

## Updating / Rebuilding

If you change `Dockerfile` or `Dockerfile.ssl`:

```bash
# Remove old images
podman rmi vscode-agent:latest vscode-agent:ssl

# Rebuild
./scripts/launcher.sh ssl-build

# Recreate your sessions
./scripts/launcher.sh ssl-create 1 /path/to/workspace
```

Extensions and token volumes are unaffected by image rebuilds.

## Sharing / Cloning This Repo

When cloning on a new machine:

```bash
bash ca/create-ca.sh          # create new CA
bash ca/gen-cert.sh ca/ vscode-server   # create server cert for this machine's IP
# Import ca/ca-cert.pem into browser
./scripts/launcher.sh ssl-build
./scripts/launcher.sh ssl-create 1 /path/to/workspace
```

The `ca/` directory never contains private keys in git. Each machine generates its own.
