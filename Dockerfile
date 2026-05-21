# ============================================================================
# Dockerfile: Microsoft Official VS Code Server Web + HTTPS + Mint-Proxy
# ============================================================================
# Complete, self-contained build of Microsoft's official vscode-server-web
# with HTTPS + mint-proxy for encrypted secret storage (ServerKeyedAESCrypto)
#
# Architecture:
#   browser → nginx (TLS :SSL_PORT) → mint-proxy (:PROXY_PORT) → VS Code (:VSCODE_PORT)
# ============================================================================

FROM mcr.microsoft.com/vscode/devcontainers/base:ubuntu-22.04

ARG PYTHON_VERSION=3.11
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
    nginx \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /etc/nginx/sites-enabled/default /etc/nginx/conf.d/default.conf

# ============================================================================
# VS Code Secret Storage (libsecret + gnome-keyring + D-Bus)
# ============================================================================
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
# uv / uvx  (install directly to /usr/local/bin so all users can execute)
# ============================================================================
RUN curl -fsSL https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR=/usr/local/bin sh

# Store uvx-installed tools (MCP servers etc.) under the workspace volume so
# they persist across container rebuilds. The directory is created at runtime
# (first uvx install) since /workspace is a bind-mount.
ENV UV_TOOL_DIR=/workspace/.uv/tools

# ============================================================================
# Directory Structure & Permissions
# ============================================================================
RUN mkdir -p /workspace && \
    chown vscode:vscode /workspace && \
    chmod 755 /workspace

# ============================================================================
# VS Code Settings Defaults
# ============================================================================
RUN mkdir -p /opt/vscode-defaults
COPY config/vscode-settings.json /opt/vscode-defaults/settings.json

# ============================================================================
# Mint Proxy (secret storage key-minting)
# ============================================================================
RUN mkdir -p /opt/mint-proxy
COPY scripts/mint-proxy.js /opt/mint-proxy.js

# ============================================================================
# VS Code Server Web (Microsoft official binary)
# ============================================================================
RUN curl -fsSL "https://update.code.visualstudio.com/latest/server-linux-x64-web/stable" \
    -o /tmp/vscode-server.tar.gz \
    && mkdir -p /opt/vscode-server \
    && tar -xzf /tmp/vscode-server.tar.gz -C /opt/vscode-server --strip-components=1 \
    && rm /tmp/vscode-server.tar.gz \
    && ln -s /opt/vscode-server/bin/code-server /usr/local/bin/code-server \
    && chown -R vscode:vscode /opt/vscode-server \
    # Patch getCwdResource in workbench.js: catch ENOPRO when file:// provider
    # is missing in VS Code web server mode (no local FS in browser context).
    # Without this, Copilot agent terminal tool fails with ENOPRO on every call.
    && sed -i \
        's|async getCwdResource(){let e=this.capabilities.get(0)?.getCwd();if(!e)return;let t;if(this.remoteAuthority?t=await this._pathService.fileURI(e):t=N.file(e),await this._fileService.exists(t))return t}|async getCwdResource(){let e=this.capabilities.get(0)?.getCwd();if(!e)return;let t;try{if(this.remoteAuthority?t=await this._pathService.fileURI(e):t=N.file(e),await this._fileService.exists(t))return t}catch(r){return}}|' \
        /opt/vscode-server/out/vs/code/browser/workbench/workbench.js

# ============================================================================
# Startup Script — HTTPS with mint-proxy
# ============================================================================
RUN mkdir -p /opt/init

COPY <<'STARTUP_HTTPS' /opt/init/startup.sh
#!/bin/bash
set -euo pipefail

SSL_PORT="${SSL_PORT:-8444}"
HTTP_PORT="${HTTP_PORT:-$((SSL_PORT - 110))}"
VSCODE_PORT="${VSCODE_PORT:-8443}"
PROXY_PORT="${PROXY_PORT:-$((VSCODE_PORT + 100))}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
TOKEN_FILE="/home/vscode/.vscode-token"

# ── Fix ownership of named volume mounts ─────────────────────────────────────
chown -R vscode:vscode /home/vscode/.vscode-server/extensions 2>/dev/null || true
chown -R vscode:vscode /home/vscode/.vscode-server/data 2>/dev/null || true
chown -R vscode:vscode /home/vscode/.config 2>/dev/null || true
chown -R vscode:vscode /home/vscode/.token-store 2>/dev/null || true

# ── First-run initialisation (also repairs corrupted settings) ────────────────
DATA_DIR="/home/vscode/.vscode-server/data"
for SCOPE in Machine User; do
    TARGET="${DATA_DIR}/${SCOPE}/settings.json"
    mkdir -p "$(dirname "${TARGET}")"
    # Write defaults if missing OR if file is not valid JSON
    if [ ! -f "${TARGET}" ] || ! python3 -c "import json,sys; json.load(open('${TARGET}'))" 2>/dev/null; then
        echo "[startup] Writing ${SCOPE}/settings.json (missing or invalid JSON)"
        cp /opt/vscode-defaults/settings.json "${TARGET}"
    fi
    chown vscode:vscode "${TARGET}"
done

# ── Git credential config ────────────────────────────────────────────────────
if [ -f /home/vscode/.git-credentials ]; then
    git config --global credential.helper 'store --file ~/.git-credentials'
    chmod 600 /home/vscode/.git-credentials 2>/dev/null || true
    echo "[startup] Git credentials loaded"
fi

# ── GitHub CLI auth ─────────────────────────────────────────────────────────
if [ -d /home/vscode/.config/gh-host ] && command -v gh &>/dev/null; then
    mkdir -p /home/vscode/.config/gh
    cp -r /home/vscode/.config/gh-host/* /home/vscode/.config/gh/ 2>/dev/null || true
    chown -R vscode:vscode /home/vscode/.config/gh 2>/dev/null || true
    chmod -R 755 /home/vscode/.config/gh 2>/dev/null || true
    su - vscode -c "gh auth setup-git" 2>/dev/null || true
    echo "[startup] GitHub CLI auth configured"
fi

# ── D-Bus + gnome-keyring ────────────────────────────────────────────────────
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    mkdir -p /run/dbus
    dbus-daemon --system --fork 2>/dev/null || true
    eval "$(dbus-launch --sh-syntax 2>/dev/null)" || true
fi
if command -v gnome-keyring-daemon &>/dev/null; then
    echo "" | gnome-keyring-daemon --unlock --foreground 2>/dev/null &
    sleep 0.5
fi

# ── Connection token ─────────────────────────────────────────────────────────
TOKEN_STORE="/home/vscode/.token-store/connection-token"
if [ -z "${VSCODE_CONNECTION_TOKEN:-}" ]; then
    if [ -f "${TOKEN_STORE}" ]; then
        VSCODE_CONNECTION_TOKEN="$(cat "${TOKEN_STORE}")"
    else
        VSCODE_CONNECTION_TOKEN="$(openssl rand -hex 32)"
        echo "${VSCODE_CONNECTION_TOKEN}" > "${TOKEN_STORE}"
        chown vscode:vscode "${TOKEN_STORE}"
        chmod 600 "${TOKEN_STORE}"
    fi
fi
echo "${VSCODE_CONNECTION_TOKEN}" > "${TOKEN_FILE}"
chown vscode:vscode "${TOKEN_FILE}"
chmod 600 "${TOKEN_FILE}"

# ── Stable machine ID ────────────────────────────────────────────────────────
STABLE_ID_FILE="/home/vscode/.vscode-server/data/stable-machine-id"
if [ ! -s "${STABLE_ID_FILE}" ] || ! grep -Eq '^[a-f0-9]{32}$' "${STABLE_ID_FILE}" 2>/dev/null; then
    mkdir -p "$(dirname "${STABLE_ID_FILE}")"
    tr -d '\n-' < /proc/sys/kernel/random/uuid > "${STABLE_ID_FILE}" || \
        openssl rand -hex 16 > "${STABLE_ID_FILE}"
    chown vscode:vscode "${STABLE_ID_FILE}" 2>/dev/null || true
    chmod 444 "${STABLE_ID_FILE}"
fi
printf '%s\n' "$(cat "${STABLE_ID_FILE}")" > /etc/machine-id

# ── nginx config — proxies to the mint-proxy, not VS Code directly ───────────
cat > /etc/nginx/conf.d/vscode.conf << NGINX_CONF
server {
    listen ${HTTP_PORT};
    return 301 https://\$host:${SSL_PORT}\$request_uri;
}

server {
    listen ${SSL_PORT} ssl;
    ssl_certificate     /etc/nginx/ssl/server.crt;
    ssl_certificate_key /etc/nginx/ssl/server.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass         http://127.0.0.1:${PROXY_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$http_host;
        proxy_read_timeout 86400;
    }
}
NGINX_CONF

GH_TOKEN=$(cat /home/vscode/.config/gh/hosts.yml 2>/dev/null | grep oauth_token | head -1 | sed "s/.*oauth_token: //" || echo "")

echo "[startup] Starting mint-proxy (127.0.0.1:${PROXY_PORT} → VS Code :${VSCODE_PORT})..."
VSCODE_PORT="${VSCODE_PORT}" PROXY_PORT="${PROXY_PORT}" node /opt/mint-proxy.js &
PROXY_PID=$!

echo "[startup] Starting nginx (HTTP redirect :${HTTP_PORT} → HTTPS :${SSL_PORT})..."
nginx -g "daemon off;" &
NGINX_PID=$!

echo "[startup] Starting VS Code Server (127.0.0.1:${VSCODE_PORT})..."
cat > /tmp/vscode-launcher.sh << LAUNCHER
#!/bin/bash
export GITHUB_TOKEN='${GH_TOKEN}'
eval "\$(dbus-launch --sh-syntax 2>/dev/null)" || true
if command -v secret-tool &>/dev/null; then
    EXISTING="\$(secret-tool lookup service GitHub account mutl3y 2>/dev/null || echo '')"
    if [ -z "\${EXISTING}" ]; then
        printf '%s' "\${GITHUB_TOKEN}" | secret-tool store --label='GitHub token' service 'GitHub' account 'mutl3y' 2>/dev/null || true
    fi
fi
exec /usr/local/bin/code-server \
    --host 127.0.0.1 \
    --port ${VSCODE_PORT} \
    --connection-token-file ${TOKEN_FILE} \
    --accept-server-license-terms \
    --agent-host-port $((${VSCODE_PORT} + 200))
LAUNCHER
chmod +x /tmp/vscode-launcher.sh
su - vscode -c /tmp/vscode-launcher.sh &
VSCODE_PID=$!

echo ""
echo "[startup-v2] ========================================================"
echo "[startup-v2] HTTPS:     https://127.0.0.1:${SSL_PORT}/?tkn=${VSCODE_CONNECTION_TOKEN}"
echo "[startup-v2] Workspace: ${WORKSPACE_DIR}"
echo "[startup-v2] Proxy:     127.0.0.1:${PROXY_PORT} (mint-key + cookies)"
echo "[startup-v2] ========================================================"
echo ""

wait -n $PROXY_PID $NGINX_PID $VSCODE_PID
echo "[startup-v2] A process exited - shutting down"
kill $PROXY_PID $NGINX_PID $VSCODE_PID 2>/dev/null || true
STARTUP_HTTPS

RUN chmod +x /opt/init/startup.sh

EXPOSE 8444
EXPOSE 8334

ENTRYPOINT ["/opt/init/startup.sh"]
