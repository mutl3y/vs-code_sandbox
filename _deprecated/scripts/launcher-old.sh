#!/bin/bash
# ============================================================================
# VS Code Multi-Session Launcher - Container Agent Execution
# ============================================================================
# Launch isolated VS Code Server sessions for agent execution
# Each session: independent container, isolated workspace, persistent settings
# ============================================================================

set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
# SSL v2 sessions (mint-proxy) use ports 8550+
SSL_V2_BASE_PORT=8550
# Internal VS Code port for v2 sessions
SSL_V2_VSCODE_BASE_PORT=9200
# Mint-proxy port for v2 sessions (VSCODE_PORT + 100)
SSL_V2_PROXY_OFFSET=100
# Default cert dir (bind-mounted at runtime)
CA_DIR="${PROJECT_DIR}/ca"

print_header() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
}

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_info() { echo -e "${BLUE}ℹ${NC} $1"; }

validate_environment() {
    print_info "Validating environment..."

    # Check for podman first, fall back to docker
    if command -v podman &> /dev/null; then
        CONTAINER_CMD="podman"
        print_info "Using podman"
    elif command -v docker &> /dev/null; then
        CONTAINER_CMD="docker"
        print_info "Using docker"
    else
        print_error "Neither podman nor docker found. Please install one."
        exit 1
    fi

    if ! $CONTAINER_CMD ps &> /dev/null; then
        print_error "Container runtime not responding. Please start podman/docker."
        exit 1
    fi

    # Check for compose tool
    if command -v podman-compose &> /dev/null; then
        COMPOSE_CMD="podman-compose"
        print_info "Using podman-compose"
    elif command -v docker-compose &> /dev/null; then
        COMPOSE_CMD="docker-compose"
        print_info "Using docker-compose"
    elif $CONTAINER_CMD compose &> /dev/null; then
        COMPOSE_CMD="$CONTAINER_CMD compose"
        print_info "Using $CONTAINER_CMD compose"
    else
        print_error "No compose tool found (podman-compose or docker-compose)"
        exit 1
    fi

    if [ ! -f "$COMPOSE_FILE" ]; then
        print_error "Compose file not found: $COMPOSE_FILE"
        exit 1
    fi

    # ── Check host Git credentials ──────────────────────────────────────────
    if [ ! -f "$HOME/.git-credentials" ] && [ ! -d "$HOME/.config/gh" ]; then
        print_warning "No Git credentials found on host (~/.git-credentials or ~/.config/gh)"
        print_info "  Run on your HOST-side setup first:"
        print_info "    git config --global credential.helper store"
        print_info "    # Then do a git push/pull to save credentials"
        print_info "    # OR: gh auth login"
    elif [ -f "$HOME/.git-credentials" ]; then
        print_success "Host Git credentials found (~/.git-credentials)"
    elif [ -d "$HOME/.config/gh" ]; then
        print_success "Host GitHub CLI auth found (~/.config/gh)"
    fi

    print_success "Environment validated"
}

build_image() {
    print_header "Building VS Code Agent Image (Microsoft Official + Mint-Proxy)"
    
    local user_uid
    local user_gid
    user_uid=$(id -u)
    user_gid=$(id -g)
    
    print_info "Building vscode-agent with USER_UID=${user_uid} USER_GID=${user_gid}..."
    print_info "  • Microsoft official vscode-server-linux-x64-web (latest stable)"
    print_info "  • HTTPS/TLS support via nginx"
    print_info "  • Mint-proxy for ServerKeyedAESCrypto encryption"
    
    $CONTAINER_CMD build \
        --build-arg USER_UID="${user_uid}" \
        --build-arg USER_GID="${user_gid}" \
        -f "${PROJECT_DIR}/Dockerfile" \
        -t vscode-agent:default \
        "${PROJECT_DIR}"
    
    if [ $? -ne 0 ]; then
        print_error "Build failed"
        exit 1
    fi
    
    # Maintain compatibility with old tag names
    $CONTAINER_CMD tag vscode-agent:default vscode-agent:stable 2>/dev/null || true
    $CONTAINER_CMD tag vscode-agent:default vscode-agent:ssl-v2 2>/dev/null || true
    $CONTAINER_CMD tag vscode-agent:default vscode-agent:latest 2>/dev/null || true
    
    print_success "Image built: vscode-agent:default"
    print_success "  Tags: stable, ssl-v2, latest"
}

ssl_v2_build_image() {
    print_header "Building VS Code Server Image"
    print_info "Building vscode-agent:default (HTTPS + ServerKeyedAESCrypto via mint-proxy)..."
    build_image
    print_success "Image ready: vscode-agent:default"
}

remove_session() {
    local session_num=$1

    print_warning "This will remove the session container and volumes"
    read -p "Are you sure? (y/N) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Cancelled"
        return
    fi

    print_info "Removing session $session_num (config volumes preserved)..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" down "vscode-session-$session_num" 2>/dev/null

    if [ $? -eq 0 ]; then
        print_success "Session $session_num removed (use 'purge' to also delete volumes)"
    else
        print_error "Failed to remove session $session_num"
    fi
}

purge_session() {
    local session_num=$1

    print_warning "This will remove the session container AND all config volumes (irreversible)"
    read -p "Are you sure? (y/N) " -n 1 -r
    echo

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Cancelled"
        return
    fi

    print_info "Purging session $session_num..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" down -v "vscode-session-$session_num" 2>/dev/null

    if [ $? -eq 0 ]; then
        print_success "Session $session_num purged"
    else
        print_error "Failed to purge session $session_num"
    fi
}

rotate_password() {
    local session_num=$1
    local new_password=$2

    if [ "$session_num" -lt 1 ] || [ "$session_num" -gt 3 ]; then
        print_error "Session number must be 1-3"
        exit 1
    fi

    if [ -z "$new_password" ]; then
        print_error "Usage: $0 rotate-password <session_number> <new_password>"
        exit 1
    fi

    local config_dir="$HOME/.vscode-container-session-$session_num"
    local config_file="$config_dir/config.yaml"

    if [ ! -f "$config_file" ]; then
        print_error "Config file not found: $config_file"
        print_info "Session may not be initialized yet"
        exit 1
    fi

    print_info "Rotating password for session $session_num..."

    # Both fix ownership and update password in the same podman unshare context
    # This ensures sed can write to the file
    if ! podman unshare bash -c "
        chown -R $(id -u):$(id -g) '$config_dir' || true
        sed -i.bak \"s/^password:.*/password: $new_password/\" '$config_file'
        rm -f '$config_file.bak'
    "; then
        print_error "Failed to update password"
        exit 1
    fi

    print_success "Password updated in config"

    # Restart the container
    print_info "Restarting container..."
    if $COMPOSE_CMD -f "$COMPOSE_FILE" restart "vscode-session-$session_num" 2>/dev/null; then
        print_success "Session $session_num restarted"
    else
        print_error "Failed to restart session $session_num"
        exit 1
    fi

    # Regenerate auto-login link with new password
    local port=$((BASE_PORT + session_num - 1))
    local host_ip=$(hostname -I | awk '{print $1}')
    local link_file="${PROJECT_DIR}/links/session-${session_num}-autologin.html"

    mkdir -p "${PROJECT_DIR}/links" 2>/dev/null || true

    cat > "$link_file" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>VS Code Session $session_num - Auto-Login</title>
    <meta http-equiv="refresh" content="0; url=https://${host_ip}:${port}#password=${new_password}" />
</head>
<body>
    <p>Redirecting to VS Code Session $session_num...</p>
    <p>If not redirected, <a href="https://${host_ip}:${port}#password=${new_password}">click here</a></p>
</body>
</html>
EOF

    print_success "Auto-login link updated: $link_file"
    echo ""
    echo -e "${GREEN}✨ New Access Details:${NC}"
    echo -e "  ${BLUE}Session:${NC}     vscode-session-$session_num"
    echo -e "  ${BLUE}Password:${NC}    $new_password"
    echo -e "  ${BLUE}Auto-login:${NC}  $link_file"
    echo -e "  ${BLUE}Direct URL:${NC}  https://${host_ip}:${port}#password=${new_password}"
}

show_logs() {
    local session_num=$1
    print_header "Logs for Session $session_num"
    $COMPOSE_CMD -f "$COMPOSE_FILE" logs -f "vscode-session-$session_num"
}

# ============================================================================
# SSL session management (direct podman run)
# DEPRECATED: The default vscode-agent:default image now includes HTTPS support
# Use ssl-v2-create instead (which uses docker-compose for consistency)
# ============================================================================

ssl_build_image() {
    print_header "Building SSL Image"
    print_warning "DEPRECATED: Use 'build' instead - default image now includes HTTPS"
    print_info "Building vscode-agent:default with Microsoft official binary + mint-proxy..."
    build_image
}

ssl_create_session() {
    local session_num=$1
    local workspace_path=$2
    local cert_dir=${3:-${CA_DIR}}

    if [[ "$session_num" -lt 1 || "$session_num" -gt 3 ]]; then
        print_error "Session number must be 1-3"
        exit 1
    fi

    local container_name="vscode-ssl-${session_num}"
    local ssl_port=$((SSL_BASE_PORT + session_num - 1))
    local vs_port=$((SSL_VSCODE_BASE_PORT + session_num - 1))
    local cert="${cert_dir}/server.crt"
    local key="${cert_dir}/server.key"

    if [[ ! -f "$cert" || ! -f "$key" ]]; then
        print_error "Certs not found: ${cert} / ${key}"
        print_info "Generate with: bash ca/gen-cert.sh ca/ vscode-server"
        exit 1
    fi

    if ! podman image inspect vscode-agent:default &>/dev/null && ! podman image inspect vscode-agent:ssl-v2 &>/dev/null; then
        print_error "Image vscode-agent:default not found. Run: $0 build"
        exit 1
    fi
    
    # Ensure we have the image
    local image_name="vscode-agent:default"
    if ! podman image inspect "${image_name}" &>/dev/null; then
        image_name="vscode-agent:ssl-v2"
    fi

    if podman ps -a --filter "name=^${container_name}$" --format '{{.Names}}' | grep -q "${container_name}"; then
        print_warning "Container ${container_name} already exists - removing it"
        podman rm -f "${container_name}" &>/dev/null
    fi

    print_header "Creating SSL Session ${session_num}"
    print_info "Port:       ${ssl_port} (HTTPS)"
    print_info "Workspace:  ${workspace_path}"
    print_info "Certs:      ${cert_dir}"

    local ext_vol="vscode-ssl-extensions-${session_num}"
    local data_vol="vscode-ssl-server-data-${session_num}"
    local config_vol="vscode-ssl-config-${session_num}"
    local token_vol="vscode-ssl-token-shared"
    print_info "Extensions: ${ext_vol} (named volume, survives ssl-remove)"
    print_info "Server data: ${data_vol} (secrets, GitHub tokens, machine ID)"
    print_info "Config:     ${config_vol} (tunnel/auth state)"
    print_info "Token:      ${token_vol} (shared across all SSL sessions)"

    podman run -d \
        --name "${container_name}" \
        --network=host \
        --userns=keep-id \
        -e SSL_PORT="${ssl_port}" \
        -e VSCODE_PORT="${vs_port}" \
        -e WORKSPACE_DIR="/workspace" \
        -v "${cert}:/etc/nginx/ssl/server.crt:ro,z" \
        -v "${key}:/etc/nginx/ssl/server.key:ro,z" \
        -v "${workspace_path}:/workspace:rw,z" \
        -v "${ext_vol}:/home/vscode/.vscode-server/extensions:rw" \
        -v "${data_vol}:/home/vscode/.vscode-server/data:rw" \
        -v "${config_vol}:/home/vscode/.config:rw" \
        -v "${token_vol}:/home/vscode/.token-store:rw" \
        -v "${HOME}/.config/gh:/home/vscode/.config/gh-host:ro,z" \
        "${image_name}"

    print_info "Waiting for startup..."
    local retries=0
    while [[ $retries -lt 20 ]]; do
        if podman exec "${container_name}" test -f /home/vscode/.vscode-token 2>/dev/null; then
            break
        fi
        retries=$((retries + 1))
        sleep 1
    done

    local token
    token=$(podman exec "${container_name}" cat /home/vscode/.vscode-token 2>/dev/null || echo "UNKNOWN")
    local host_ip
    host_ip=$(hostname -I | awk '{print $1}')
    [[ -z "$host_ip" ]] && host_ip="127.0.0.1"

    print_success "SSL Session ${session_num} running"
    echo ""
    echo -e "  ${BLUE}Container:${NC}  ${container_name}"
    echo -e "  ${BLUE}URL:${NC}        https://${host_ip}:${ssl_port}/?tkn=${token}&folder=/workspace"
    echo -e "  ${BLUE}Workspace:${NC}  ${workspace_path}"
    echo ""
}

ssl_stop_session() {
    local session_num=$1
    local container_name="vscode-ssl-${session_num}"
    print_info "Stopping ${container_name}..."
    podman stop "${container_name}" 2>/dev/null && print_success "${container_name} stopped" || print_error "Failed to stop ${container_name}"
}

ssl_remove_session() {
    local session_num=$1
    local container_name="vscode-ssl-${session_num}"
    print_warning "This will remove container ${container_name} (extensions/data/config volumes preserved)"
    read -p "Are you sure? (y/N) " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { print_info "Cancelled"; return; }
    podman rm -f "${container_name}" 2>/dev/null && print_success "${container_name} removed (volumes preserved: vscode-ssl-extensions-${session_num}, vscode-ssl-server-data-${session_num}, vscode-ssl-config-${session_num})" || print_error "Failed to remove ${container_name}"
}

ssl_purge_session() {
    local session_num=$1
    local container_name="vscode-ssl-${session_num}"
    local ext_vol="vscode-ssl-extensions-${session_num}"
    local data_vol="vscode-ssl-server-data-${session_num}"
    local config_vol="vscode-ssl-config-${session_num}"
    print_warning "This will remove container ${container_name} and its extensions/data/config volumes (irreversible)"
    print_info  "Shared token volume is preserved unless all sessions are purged"
    read -p "Are you sure? (y/N) " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { print_info "Cancelled"; return; }
    podman rm -f "${container_name}" 2>/dev/null || true
    if podman volume inspect "${ext_vol}" &>/dev/null; then
        podman volume rm "${ext_vol}" && print_success "${ext_vol} removed" || print_error "Failed to remove ${ext_vol}"
    else
        print_info "Volume ${ext_vol} does not exist"
    fi
    if podman volume inspect "${data_vol}" &>/dev/null; then
        podman volume rm "${data_vol}" && print_success "${data_vol} removed" || print_error "Failed to remove ${data_vol}"
    else
        print_info "Volume ${data_vol} does not exist"
    fi
    if podman volume inspect "${config_vol}" &>/dev/null; then
        podman volume rm "${config_vol}" && print_success "${config_vol} removed" || print_error "Failed to remove ${config_vol}"
    else
        print_info "Volume ${config_vol} does not exist"
    fi
    # Remove shared token volume only if no other SSL sessions exist
    local token_vol="vscode-ssl-token-shared"
    local remaining=0
    for n in 1 2 3; do
        [[ $n -eq $session_num ]] && continue
        podman ps -a --filter "name=^vscode-ssl-${n}$" --format '{{.Names}}' 2>/dev/null | grep -q "vscode-ssl-${n}" && remaining=$((remaining + 1)) || true
    done
    if [[ $remaining -eq 0 ]]; then
        if podman volume inspect "${token_vol}" &>/dev/null; then
            podman volume rm "${token_vol}" && print_success "${token_vol} removed (no sessions remain)" || true
        fi
    else
        print_info "Shared token volume retained (${remaining} other session(s) exist)"
    fi
    print_success "${container_name} purged"
}

# ============================================================================
# SSL v2 session management (mint-proxy for ServerKeyedAESCrypto)
# NOTE: v2 is now the DEFAULT - all sessions run with mint-proxy + ServerKeyedAESCrypto
# Image: vscode-agent:default  Ports: 8550, 8551, 8552
# ============================================================================

ssl_v2_build_image() {
    print_header "Building VS Code Server Image"
    print_info "Building vscode-agent:default (HTTPS + ServerKeyedAESCrypto via mint-proxy)..."
    build_image
    print_success "Image ready: vscode-agent:default"
}

ssl_v2_create_session() {
    local session_num=$1
    local workspace_path=$2
    local cert_dir=${3:-${CA_DIR}}

    if [[ "$session_num" -lt 1 || "$session_num" -gt 3 ]]; then
        print_error "Session number must be 1-3"
        exit 1
    fi

    local container_name="vscode-ssl-v2-${session_num}"
    local ssl_port=$((SSL_V2_BASE_PORT + session_num - 1))
    local vs_port=$((SSL_V2_VSCODE_BASE_PORT + session_num - 1))
    local proxy_port=$((vs_port + SSL_V2_PROXY_OFFSET))
    local cert="${cert_dir}/server.crt"
    local key="${cert_dir}/server.key"

    if [[ ! -f "$cert" || ! -f "$key" ]]; then
        print_error "Certs not found: ${cert} / ${key}"
        print_info "Generate with: bash ca/gen-cert.sh ca/ vscode-server"
        exit 1
    fi

    # Ensure we have the default image (v2)
    if ! podman image inspect vscode-agent:default &>/dev/null && ! podman image inspect vscode-agent:ssl-v2 &>/dev/null; then
        print_error "Image vscode-agent:default not found. Run: $0 build"
        exit 1
    fi
    
    local image_name="vscode-agent:default"
    if ! podman image inspect "${image_name}" &>/dev/null; then
        image_name="vscode-agent:ssl-v2"
    fi

    if podman ps -a --filter "name=^${container_name}$" --format '{{.Names}}' | grep -q "${container_name}"; then
        print_warning "Container ${container_name} already exists - removing it"
        podman rm -f "${container_name}" &>/dev/null
    fi

    print_header "Creating SSL v2 Session ${session_num} (mint-proxy)"
    print_info "Port:        ${ssl_port} (HTTPS)"
    print_info "Workspace:   ${workspace_path}"
    print_info "Certs:       ${cert_dir}"
    print_info "Proxy port:  ${proxy_port} (mint + cookies)"
    print_info "VS Code:     ${vs_port} (loopback)"

    local ext_vol="vscode-ssl-v2-extensions-${session_num}"
    local data_vol="vscode-ssl-v2-server-data-${session_num}"
    local config_vol="vscode-ssl-v2-config-${session_num}"
    local token_vol="vscode-ssl-v2-token-shared"
    print_info "Extensions:  ${ext_vol}"
    print_info "Server data: ${data_vol}"
    print_info "Config:      ${config_vol}"
    print_info "Token:       ${token_vol}"

    podman run -d \
        --name "${container_name}" \
        --network=host \
        --userns=keep-id \
        -e SSL_PORT="${ssl_port}" \
        -e VSCODE_PORT="${vs_port}" \
        -e PROXY_PORT="${proxy_port}" \
        -e WORKSPACE_DIR="/workspace" \
        -v "${cert}:/etc/nginx/ssl/server.crt:ro,z" \
        -v "${key}:/etc/nginx/ssl/server.key:ro,z" \
        -v "${workspace_path}:/workspace:rw,z" \
        -v "${ext_vol}:/home/vscode/.vscode-server/extensions:rw" \
        -v "${data_vol}:/home/vscode/.vscode-server/data:rw" \
        -v "${config_vol}:/home/vscode/.config:rw" \
        -v "${token_vol}:/home/vscode/.token-store:rw" \
        -v "${HOME}/.config/gh:/home/vscode/.config/gh-host:ro,z" \
        "${image_name}"

    print_info "Waiting for startup..."
    local retries=0
    while [[ $retries -lt 20 ]]; do
        if podman exec "${container_name}" test -f /home/vscode/.vscode-token 2>/dev/null; then
            break
        fi
        retries=$((retries + 1))
        sleep 1
    done

    local token
    token=$(podman exec "${container_name}" cat /home/vscode/.vscode-token 2>/dev/null || echo "UNKNOWN")
    local host_ip
    host_ip=$(hostname -I | awk '{print $1}')
    [[ -z "$host_ip" ]] && host_ip="127.0.0.1"

    print_success "SSL v2 Session ${session_num} running"
    echo ""
    echo -e "  ${BLUE}Container:${NC}  ${container_name}"
    echo -e "  ${BLUE}URL:${NC}        https://${host_ip}:${ssl_port}/?tkn=${token}&folder=/workspace"
    echo -e "  ${BLUE}Workspace:${NC}  ${workspace_path}"
    echo -e "  ${BLUE}Note:${NC}       Uses mint-proxy for ServerKeyedAESCrypto secret storage"
    echo ""
}

ssl_v2_stop_session() {
    local container_name="vscode-ssl-v2-$1"
    print_info "Stopping ${container_name}..."
    podman stop "${container_name}" 2>/dev/null && print_success "${container_name} stopped" || print_error "Failed to stop ${container_name}"
}

ssl_v2_remove_session() {
    local session_num=$1
    local container_name="vscode-ssl-v2-${session_num}"
    print_warning "This will remove container ${container_name} (volumes preserved)"
    read -p "Are you sure? (y/N) " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { print_info "Cancelled"; return; }
    podman rm -f "${container_name}" 2>/dev/null && print_success "${container_name} removed" || print_error "Failed to remove ${container_name}"
}

ssl_v2_list_sessions() {
    print_header "Active SSL v2 Sessions (mint-proxy)"
    local found=0
    local host_ip
    host_ip=$(hostname -I | awk '{print $1}')
    [[ -z "$host_ip" ]] && host_ip="127.0.0.1"
    for n in 1 2 3; do
        local container_name="vscode-ssl-v2-${n}"
        local ssl_port=$((SSL_V2_BASE_PORT + n - 1))
        if podman ps --filter "name=^${container_name}$" --format '{{.Names}}' 2>/dev/null | grep -q "${container_name}"; then
            local token
            token=$(podman exec "${container_name}" cat /home/vscode/.vscode-token 2>/dev/null || echo "UNKNOWN")
            echo -e "  ${GREEN}●${NC} ${container_name}  https://${host_ip}:${ssl_port}/?tkn=${token}&folder=/workspace"
            found=$((found + 1))
        fi
    done
    [[ $found -eq 0 ]] && print_info "No active SSL v2 sessions"
}

ssl_v2_token_session() {
    local session_num=$1
    local container_name="vscode-ssl-v2-${session_num}"
    local ssl_port=$((SSL_V2_BASE_PORT + session_num - 1))
    local token
    token=$(podman exec "${container_name}" cat /home/vscode/.vscode-token 2>/dev/null) || {
        print_error "Container ${container_name} not running"
        exit 1
    }
    local host_ip
    host_ip=$(hostname -I | awk '{print $1}')
    [[ -z "$host_ip" ]] && host_ip="127.0.0.1"
    echo "https://${host_ip}:${ssl_port}/?tkn=${token}&folder=/workspace"
}

ssl_list_sessions() {
    print_header "Active SSL Sessions"
    local found=0
    local host_ip
    host_ip=$(hostname -I | awk '{print $1}')
    [[ -z "$host_ip" ]] && host_ip="127.0.0.1"
    for n in 1 2 3; do
        local container_name="vscode-ssl-${n}"
        local ssl_port=$((SSL_BASE_PORT + n - 1))
        if podman ps --filter "name=^${container_name}$" --format '{{.Names}}' 2>/dev/null | grep -q "${container_name}"; then
            local token
            token=$(podman exec "${container_name}" cat /home/vscode/.vscode-token 2>/dev/null || echo "UNKNOWN")
            echo -e "  ${GREEN}●${NC} ${container_name}  https://${host_ip}:${ssl_port}/?tkn=${token}&folder=/workspace"
            found=$((found + 1))
        fi
    done
    if [[ $found -eq 0 ]]; then
        print_info "No active SSL sessions"
    fi
}

ssl_token_session() {
    local session_num=$1
    local container_name="vscode-ssl-${session_num}"
    local ssl_port=$((SSL_BASE_PORT + session_num - 1))
    local token
    token=$(podman exec "${container_name}" cat /home/vscode/.vscode-token 2>/dev/null) || {
        print_error "Container ${container_name} not running"
        exit 1
    }
    local host_ip
    host_ip=$(hostname -I | awk '{print $1}')
    [[ -z "$host_ip" ]] && host_ip="127.0.0.1"
    echo "https://${host_ip}:${ssl_port}/?tkn=${token}&folder=/workspace"
}

show_usage() {
    cat << EOF
${BLUE}VS Code Multi-Session Launcher${NC}
${BLUE}========================================${NC}

${YELLOW}RECOMMENDED WORKFLOW:${NC}
  1. Generate certificates:  bash ca/gen-cert.sh ca/ vscode-server
  2. Build image:            $0 build
  3. Create SSL v2 session:  $0 ssl-v2-create 1 /path/to/workspace
  4. Access:                 See output for HTTPS URL

${YELLOW}NOTE:${NC} The default image now includes:
  • Microsoft official vscode-server-linux-x64-web binary (latest stable)
  • HTTPS/TLS via nginx
  • Mint-proxy for ServerKeyedAESCrypto encryption
  • No fork dependency - pure public release

${BLUE}Commands:${NC}

Build Image:
  ${GREEN}build${NC}                                   Build vscode-agent:default (HTTPS + mint-proxy)

SSL v2 Sessions (RECOMMENDED - ports 8550-8552):
  ${GREEN}ssl-v2-create${NC} <session> <path> [cert_dir]  Create HTTPS session (mint-proxy for encryption)
  ${GREEN}ssl-v2-list${NC}                                 List active sessions
  ${GREEN}ssl-v2-token${NC} <session>                      Print access URL
  ${GREEN}ssl-v2-remove${NC} <session>                     Remove container (volumes preserved)

Legacy HTTP Sessions (not recommended):
  ${GREEN}create${NC} <session> <path> [pwd]           Create HTTP session (no auth)
  ${GREEN}list${NC}                                     List active sessions

Support:
  Documentation: docs/HTTPS_SETUP.md
  Cert dir:      ${PROJECT_DIR}/ca/

Examples:
  $0 build
  $0 ssl-v2-create 1 /workspace/myproject
  $0 ssl-v2-list
  $0 ssl-v2-token 1

Ports:
  Session 1: 8550  |  Session 2: 8551  |  Session 3: 8552

EOF
}

main() {
    if [ $# -eq 0 ]; then
        show_usage
        exit 1
    fi

    validate_environment

    local command=$1
    shift

    case "$command" in
        build)
            build_image
            ;;
        ssl-v2-build)
            ssl_v2_build_image
            ;;
        ssl-v2-create)
            [[ $# -lt 2 ]] && { print_error "Usage: $0 ssl-v2-create <session_number> <workspace_path> [cert_dir]"; exit 1; }
            ssl_v2_create_session "$1" "$2" "${3:-}"
            ;;
        ssl-v2-stop)
            [[ $# -lt 1 ]] && { print_error "Usage: $0 ssl-v2-stop <session_number>"; exit 1; }
            ssl_v2_stop_session "$1"
            ;;
        ssl-v2-remove)
            [[ $# -lt 1 ]] && { print_error "Usage: $0 ssl-v2-remove <session_number>"; exit 1; }
            ssl_v2_remove_session "$1"
            ;;
        ssl-v2-list)
            ssl_v2_list_sessions
            ;;
        ssl-v2-token)
            [[ $# -lt 1 ]] && { print_error "Usage: $0 ssl-v2-token <session_number>"; exit 1; }
            ssl_v2_token_session "$1"
            ;;
        *)
            print_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
