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

# Match the vscode user uid/gid to the host user running the build
# Avoids permission issues on bind-mounted workspaces
ARG USER_UID=1000
ARG USER_GID=1000
RUN if [ "${USER_UID}" != "1000" ] || [ "${USER_GID}" != "1000" ]; then \
        groupmod -g "${USER_GID}" vscode && \
        usermod -u "${USER_UID}" -g "${USER_GID}" vscode; \
    fi

# ============================================================================
# System Dependencies
# ============================================================================
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# ============================================================================
# VS Code Secret Storage (libsecret + gnome-keyring + D-Bus)
# ============================================================================
# VS Code Server Web needs a persistent secret store to save GitHub/Copilot
# auth tokens. Without it, tokens are stored in browser IndexedDB only and
# lost on refresh. gnome-keyring + libsecret provide the server-side store.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsecret-1-0 \
    libsecret-tools \
    gnome-keyring \
    dbus \
    dbus-x11 \
    && rm -rf /var/lib/apt/lists/*

# ============================================================================
# GitHub CLI
# ============================================================================
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# ============================================================================
# Node.js (latest LTS) & npm
# ============================================================================
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
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
# Store VS Code settings as defaults - copied into the persistent data volume
# on first boot so they don't get shadowed by the volume mount.
RUN mkdir -p /opt/vscode-defaults
COPY config/vscode-settings.json /opt/vscode-defaults/settings.json

RUN mkdir -p /opt/init

COPY <<'STARTUP_SCRIPT' /opt/init/startup.sh
#!/bin/bash
set -euo pipefail

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"

# ── First-run initialisation of the persistent data volume ──────────────────
# The volume at /home/vscode/.vscode-server/data/ starts empty on first use.
# Populate Machine and User settings from the baked-in defaults so VS Code
# picks them up without needing a rebuild.
# On subsequent starts the files already exist and this is a no-op.
DATA_DIR="/home/vscode/.vscode-server/data"
for SCOPE in Machine User; do
    TARGET="${DATA_DIR}/${SCOPE}/settings.json"
    if [ ! -f "${TARGET}" ]; then
        echo "[startup] First-run init: writing ${SCOPE}/settings.json"
        mkdir -p "$(dirname "${TARGET}")"
        cp /opt/vscode-defaults/settings.json "${TARGET}"
        chown vscode:vscode "${TARGET}"
    fi
done

echo "[startup] VS Code Server - HTTP mode"
echo "[startup] Workspace: ${WORKSPACE_DIR}"

# ── Git credential config ──────────────────────────────────────────────────
# Credentials mounted from host at /home/vscode/.git-credentials (read-only)
if [ -f /home/vscode/.git-credentials ]; then
    git config --global credential.helper 'store --file ~/.git-credentials'
    chmod 600 /home/vscode/.git-credentials 2>/dev/null || true
    echo "[startup] Git credentials loaded from host mount"
fi

# ── GitHub CLI auth ─────────────────────────────────────────────────────────
# gh CLI config mounted from host at /home/vscode/.config/gh-host (read-only)
# Copy into the persisted .config volume so gh auth status works
if [ -d /home/vscode/.config/gh-host ] && command -v gh &>/dev/null; then
    mkdir -p /home/vscode/.config/gh
    cp -r /home/vscode/.config/gh-host/* /home/vscode/.config/gh/ 2>/dev/null || true
    chmod -R 755 /home/vscode/.config/gh 2>/dev/null || true
    # Configure git to use gh as credential helper
    gh auth setup-git 2>/dev/null || true
    echo "[startup] GitHub CLI auth configured from host mount"
fi
echo "[startup] Access at: http://127.0.0.1:8443/?folder=${WORKSPACE_DIR}"
echo "[startup] Listening on localhost only (use nginx on :8444 for external HTTPS access)"

# ── Start D-Bus (needed for gnome-keyring / libsecret) ────────────────────
# VS Code uses libsecret to store auth tokens. This needs a D-Bus session.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    mkdir -p /run/dbus
    dbus-daemon --system --fork 2>/dev/null || true
    eval "$(dbus-launch --sh-syntax 2>/dev/null)" || true
    echo "[startup] D-Bus session started for secret storage"
fi

# ── Unlock gnome-keyring (needed for VS Code secret persistence) ────────────
if command -v gnome-keyring-daemon &>/dev/null; then
    echo "" | gnome-keyring-daemon --unlock --foreground 2>/dev/null &
    sleep 0.5
    echo "[startup] gnome-keyring unlocked for secret storage"
fi


# ── Stable machine ID ────────────────────────────────────────────────────────
# /etc/machine-id is regenerated on every container rebuild, which breaks
# VS Code's encrypted secrets store (API keys, GitHub tokens). Persist a
# stable ID inside the server volume so secrets survive rebuilds.
STABLE_ID_FILE="/home/vscode/.vscode-server/data/stable-machine-id"
if [ ! -f "${STABLE_ID_FILE}" ]; then
    echo "[startup] Generating stable machine ID (first boot)..."
    mkdir -p "$(dirname "${STABLE_ID_FILE}")"
    cat /proc/sys/kernel/random/uuid | tr -d '-\n' > "${STABLE_ID_FILE}"
    chmod 444 "${STABLE_ID_FILE}"
fi
echo "[startup] Applying stable machine ID..."
cat "${STABLE_ID_FILE}" > /etc/machine-id

# Start VS Code Server with GitHub token from host gh CLI auth
# GITHUB_TOKEN is read by VS Code's built-in GitHub auth provider
GH_TOKEN=$(cat /home/vscode/.config/gh/hosts.yml 2>/dev/null | grep oauth_token | head -1 | sed "s/.*oauth_token: //" || echo "")
if [ -n "${GH_TOKEN}" ]; then
    echo "[startup] GitHub token injected from host gh CLI"
    cat > /tmp/vscode-launcher.sh << LAUNCHER
#!/bin/bash
export GITHUB_TOKEN='${GH_TOKEN}'

# Start D-Bus session as vscode user and populate gnome-keyring
eval "\$(dbus-launch --sh-syntax 2>/dev/null)" || true
if command -v secret-tool &>/dev/null; then
    EXISTING="\$(secret-tool lookup service GitHub account mutl3y 2>/dev/null || echo '')"
    if [ -z "\${EXISTING}" ]; then
        printf '%s' "\${GITHUB_TOKEN}" | secret-tool store --label='GitHub token' service 'GitHub' account 'mutl3y' 2>/dev/null || true
    fi
fi
exec /usr/local/bin/code-server --host 127.0.0.1 --port 8443 --without-connection-token --accept-server-license-terms
LAUNCHER
    chmod +x /tmp/vscode-launcher.sh
    exec su - vscode -c /tmp/vscode-launcher.sh
fi

exec su - vscode -c "/usr/local/bin/code-server --host 127.0.0.1 --port 8443 --without-connection-token --accept-server-license-terms"
STARTUP_SCRIPT

RUN chmod +x /opt/init/startup.sh

EXPOSE 8443

# Install VS Code Server web binary (server-linux-x64-web = browser UI)
# Note: the web binary stores auth tokens in browser IndexedDB (not server-side).
# Logging in via the browser each session is expected for this binary type.
RUN curl -fsSL "https://update.code.visualstudio.com/latest/server-linux-x64-web/stable" \
    -o /tmp/vscode-server.tar.gz && \
    tar -xzf /tmp/vscode-server.tar.gz -C /usr/local/lib/ && \
    ln -sf /usr/local/lib/vscode-server-linux-x64-web/bin/code-server /usr/local/bin/code-server && \
    rm -f /tmp/vscode-server.tar.gz && \
    echo "✓ VS Code Server (web) binary installed"

# ── Patch: Force persistent secret storage ──────────────────────────────────
# The browser-side workbench.js checks if remoteAuthority is set and a
# vscode-secret-key-path cookie exists. If the cookie is missing (which it is
# in our setup), secretStorageProvider is set to undefined, causing secrets
# to be stored in-memory only. This patch always uses
# LocalStorageSecretStorageProvider so GitHub auth tokens persist in the
# browser's localStorage across page loads.
RUN sed -i 's/secretStorageProvider:e\.remoteAuthority&&!t?void 0:new tzi(o)/secretStorageProvider:new tzi(o)/' \
    /usr/local/lib/vscode-server-linux-x64-web/out/vs/code/browser/workbench/workbench.js && \
    echo "✓ Patched workbench.js for persistent secret storage"

ENTRYPOINT ["/opt/init/startup.sh"]
