# ============================================================================
# Dockerfile: VS Code Server (Microsoft Official) - HTTP TEST MODE
# ============================================================================
# Testing container using Microsoft's official VS Code Server
# ├─ Microsoft official @vscode/cli package
# ├─ Plain HTTP (no TLS, no nginx proxy)
# ├─ No authentication
# ├─ Full development toolchain
# └─ Persistent user data volume
# ============================================================================

FROM mcr.microsoft.com/vscode/devcontainers/base:ubuntu-22.04

LABEL description="VS Code Server (Microsoft Official) - HTTP TEST MODE (no TLS, no proxy)"
LABEL maintainer="Mutl3y"

ARG PYTHON_VERSION=3.11

# ============================================================================
# System Dependencies
# ============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    && rm -rf /var/lib/apt/lists/*

# ============================================================================
# Directory Structure & Permissions
# ============================================================================
RUN mkdir -p /workspace && \
    chown vscode:vscode /workspace && \
    chmod 755 /workspace

# ============================================================================
# Startup Script
# ============================================================================
# Bake VS Code settings into both Machine and User scopes at build time
# Machine scope: read by the server process
# User scope: read by the web client (needed to suppress trust dialog)
RUN mkdir -p /home/vscode/.vscode-server/data/Machine \
    && mkdir -p /home/vscode/.vscode-server/data/User \
    && chown -R vscode:vscode /home/vscode/.vscode-server
COPY config/vscode-settings.json /home/vscode/.vscode-server/data/Machine/settings.json
COPY config/vscode-settings.json /home/vscode/.vscode-server/data/User/settings.json
RUN chown vscode:vscode \
    /home/vscode/.vscode-server/data/Machine/settings.json \
    /home/vscode/.vscode-server/data/User/settings.json

RUN mkdir -p /opt/init

COPY <<'STARTUP_SCRIPT' /opt/init/startup.sh
#!/bin/bash
set -euo pipefail

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"

echo "[startup] VS Code Server - HTTP mode"
echo "[startup] Workspace: ${WORKSPACE_DIR}"
echo "[startup] Access at: http://127.0.0.1:8443/?folder=${WORKSPACE_DIR}"
echo "[startup] Listening on localhost only (use nginx on :8444 for external HTTPS access)"

# Start VS Code Server on localhost only - not accessible externally without nginx
exec su - vscode -c "/usr/local/bin/code-server --host 127.0.0.1 --port 8443 --without-connection-token --accept-server-license-terms"
STARTUP_SCRIPT

RUN chmod +x /opt/init/startup.sh

EXPOSE 8443

# Install VS Code Server web binary (server-linux-x64-web = browser UI)
# IMPORTANT: must be server-linux-x64-web, NOT server-linux-x64 (SSH-only)
RUN curl -fsSL "https://update.code.visualstudio.com/latest/server-linux-x64-web/stable" \
    -o /tmp/vscode-server.tar.gz && \
    tar -xzf /tmp/vscode-server.tar.gz -C /usr/local/lib/ && \
    ln -sf /usr/local/lib/vscode-server-linux-x64-web/bin/code-server /usr/local/bin/code-server && \
    rm -f /tmp/vscode-server.tar.gz && \
    echo "✓ VS Code Server (web) binary installed"

ENTRYPOINT ["/opt/init/startup.sh"]
