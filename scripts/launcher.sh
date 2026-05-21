#!/bin/bash
# ============================================================================
# VS Code Multi-Session Launcher - Container Agent Execution (HTTPS + Mint-Proxy)
# ============================================================================
# Launch isolated VS Code Server sessions with HTTPS/TLS encryption
# Single image: vscode-agent:default (Microsoft official + mint-proxy)
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
SSL_V2_VSCODE_BASE_PORT=9200
SSL_V2_PROXY_OFFSET=100
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

    if command -v podman &> /dev/null; then
        CONTAINER_CMD="podman"
        print_info "Using podman"
    elif command -v docker &> /dev/null; then
        CONTAINER_CMD="docker"
        print_info "Using docker"
    else
        print_error "Neither podman nor docker found"
        exit 1
    fi

    if ! $CONTAINER_CMD ps &> /dev/null; then
        print_error "Container runtime not responding"
        exit 1
    fi

    if command -v podman-compose &> /dev/null; then
        COMPOSE_CMD="podman-compose"
    elif command -v docker-compose &> /dev/null; then
        COMPOSE_CMD="docker-compose"
    elif $CONTAINER_CMD compose &> /dev/null; then
        COMPOSE_CMD="$CONTAINER_CMD compose"
    else
        print_error "No compose tool found"
        exit 1
    fi

    [[ -f "$COMPOSE_FILE" ]] || { print_error "Compose file not found: $COMPOSE_FILE"; exit 1; }
    print_success "Environment validated"
}

build_image() {
    print_header "Building VS Code Server Image (Microsoft Official + Mint-Proxy)"

    local user_uid=$(id -u)
    local user_gid=$(id -g)

    print_info "Building vscode-agent:default with USER_UID=${user_uid} USER_GID=${user_gid}"
    print_info "  • Microsoft official vscode-server-linux-x64-web (latest stable)"
    print_info "  • HTTPS/TLS via nginx"
    print_info "  • Mint-proxy for ServerKeyedAESCrypto encryption"

    $CONTAINER_CMD build \
        --build-arg USER_UID="${user_uid}" \
        --build-arg USER_GID="${user_gid}" \
        -f "${PROJECT_DIR}/Dockerfile" \
        -t vscode-agent:default \
        "${PROJECT_DIR}" || { print_error "Build failed"; exit 1; }

    $CONTAINER_CMD tag vscode-agent:default vscode-agent:stable 2>/dev/null || true
    $CONTAINER_CMD tag vscode-agent:default vscode-agent:ssl-v2 2>/dev/null || true
    $CONTAINER_CMD tag vscode-agent:default vscode-agent:latest 2>/dev/null || true

    print_success "Image built: vscode-agent:default (tags: stable, ssl-v2, latest)"
}

create_session() {
    local session_num=$1 workspace_path=$2 cert_dir=${3:-${CA_DIR}}

    [[ "$session_num" -lt 1 || "$session_num" -gt 3 ]] && { print_error "Session must be 1-3"; exit 1; }

    local container_name="vscode-ssl-v2-${session_num}"
    local ssl_port=$((SSL_V2_BASE_PORT + session_num - 1))
    local http_port=$((ssl_port - 110))
    local vs_port=$((SSL_V2_VSCODE_BASE_PORT + session_num - 1))
    local proxy_port=$((vs_port + SSL_V2_PROXY_OFFSET))
    local cert="${cert_dir}/server.crt" key="${cert_dir}/server.key"

    [[ -f "$cert" && -f "$key" ]] || { print_error "Certs not found: $cert / $key"; print_info "Generate with: bash ca/gen-cert.sh ca/ vscode-server"; exit 1; }

    if ! podman image inspect vscode-agent:default &>/dev/null && ! podman image inspect vscode-agent:ssl-v2 &>/dev/null; then
        print_error "Image not found. Run: $0 build"
        exit 1
    fi

    local image_name="vscode-agent:default"
    podman image inspect "${image_name}" &>/dev/null || image_name="vscode-agent:ssl-v2"

    podman ps -a --filter "name=^${container_name}$" --format '{{.Names}}' | grep -q "${container_name}" && podman rm -f "${container_name}" &>/dev/null

    print_header "Creating Session ${session_num} (HTTPS + Mint-Proxy)"
    print_info "Port: ${ssl_port} (HTTPS)  ${http_port} (HTTP→redirect)  |  Workspace: ${workspace_path}"

    podman run -d \
        --name "${container_name}" \
        --network=host \
        --userns=keep-id \
        -e SSL_PORT="${ssl_port}" \
        -e HTTP_PORT="${http_port}" \
        -e VSCODE_PORT="${vs_port}" \
        -e PROXY_PORT="${proxy_port}" \
        -e WORKSPACE_DIR="/workspace" \
        -v "${cert}:/etc/nginx/ssl/server.crt:ro,z" \
        -v "${key}:/etc/nginx/ssl/server.key:ro,z" \
        -v "${workspace_path}:/workspace:rw,z" \
        -v "vscode-ssl-v2-extensions-${session_num}:/home/vscode/.vscode-server/extensions:rw" \
        -v "vscode-ssl-v2-server-data-${session_num}:/home/vscode/.vscode-server/data:rw" \
        -v "vscode-ssl-v2-config-${session_num}:/home/vscode/.config:rw" \
        -v "vscode-ssl-v2-token-shared:/home/vscode/.token-store:rw" \
        -v "${HOME}/.config/gh:/home/vscode/.config/gh-host:ro,z" \
        "${image_name}"

    print_info "Waiting for startup..."
    local retries=0
    while [[ $retries -lt 20 ]]; do
        podman exec "${container_name}" test -f /home/vscode/.vscode-token 2>/dev/null && break
        retries=$((retries + 1))
        sleep 1
    done

    local token=$(podman exec "${container_name}" cat /home/vscode/.vscode-token 2>/dev/null || echo "UNKNOWN")
    local host_ip=$(hostname -I | awk '{print $1}')
    [[ -z "$host_ip" ]] && host_ip="127.0.0.1"

    print_success "Session ${session_num} ready"
    echo ""
    echo -e "  ${BLUE}URL:${NC}        https://${host_ip}:${ssl_port}/?tkn=${token}&folder=/workspace"
    echo -e "  ${BLUE}Container:${NC}   ${container_name}"
    echo -e "  ${BLUE}Workspace:${NC}   ${workspace_path}"
    echo ""
}

list_sessions() {
    print_header "Active Sessions"
    local found=0 host_ip=$(hostname -I | awk '{print $1}')
    [[ -z "$host_ip" ]] && host_ip="127.0.0.1"

    for n in 1 2 3; do
        local container_name="vscode-ssl-v2-${n}" ssl_port=$((SSL_V2_BASE_PORT + n - 1))
        if podman ps --filter "name=^${container_name}$" --format '{{.Names}}' 2>/dev/null | grep -q "${container_name}"; then
            local token=$(podman exec "${container_name}" cat /home/vscode/.vscode-token 2>/dev/null || echo "UNKNOWN")
            echo -e "  ${GREEN}●${NC} ${container_name}  https://${host_ip}:${ssl_port}/?tkn=${token}&folder=/workspace"
            found=$((found + 1))
        fi
    done
    [[ $found -eq 0 ]] && print_info "No active sessions"
}

token_session() {
    local session_num=$1 container_name="vscode-ssl-v2-${session_num}" ssl_port=$((SSL_V2_BASE_PORT + session_num - 1))
    local token=$(podman exec "${container_name}" cat /home/vscode/.vscode-token 2>/dev/null) || { print_error "Container not running"; exit 1; }
    local host_ip=$(hostname -I | awk '{print $1}')
    [[ -z "$host_ip" ]] && host_ip="127.0.0.1"
    echo "https://${host_ip}:${ssl_port}/?tkn=${token}&folder=/workspace"
}

remove_session() {
    local session_num=$1 container_name="vscode-ssl-v2-${session_num}"
    print_warning "Remove container ${container_name}? (volumes preserved)"
    read -p "(y/N) " -n 1 -r && echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { print_info "Cancelled"; return; }
    podman rm -f "${container_name}" 2>/dev/null && print_success "Removed" || print_error "Failed"
}

purge_session() {
    local session_num=$1 container_name="vscode-ssl-v2-${session_num}"
    print_warning "PURGE session ${session_num}? This removes the container AND all its volumes (extensions, config, server data)."
    read -p "Type 'yes' to confirm: " -r && echo
    [[ "$REPLY" != "yes" ]] && { print_info "Cancelled"; return; }
    podman rm -f "${container_name}" 2>/dev/null || true
    for vol in extensions server-data config; do
        podman volume rm "vscode-ssl-v2-${vol}-${session_num}" 2>/dev/null && print_success "Removed volume: vscode-ssl-v2-${vol}-${session_num}" || true
    done
    print_success "Session ${session_num} purged"
}

stop_session() {
    local container_name="vscode-ssl-v2-$1"
    podman stop "${container_name}" 2>/dev/null && print_success "Stopped" || print_error "Failed"
}

show_usage() {
    cat << 'EOF'
╔════════════════════════════════════════════════════════════╗
║  VS Code Multi-Session Launcher (HTTPS + Mint-Proxy)      ║
╚════════════════════════════════════════════════════════════╝

QUICK START:
  1. Generate certs:    bash ca/gen-cert.sh ca/ vscode-server
  2. Build image:       ./scripts/launcher.sh build
  3. Create session:    ./scripts/launcher.sh create 1 /workspace
  4. Access:            https://127.0.0.1:8550/?tkn=<token>&folder=/workspace

COMMANDS:
  build                          Build image (Microsoft official + mint-proxy)
  create  <n> <path> [certs]    Create HTTPS session (n=1-3, path=/workspace)
  list                           List active sessions with URLs
  token   <n>                    Print access URL for session n
  stop    <n>                    Stop session (volumes preserved)
  remove  <n>                    Remove container (volumes preserved)
  purge   <n>                    Remove container AND all volumes (clean slate)

DEFAULT PORTS:  8550 (session 1)  |  8551 (session 2)  |  8552 (session 3)

ARCHITECTURE:
  ✓ Microsoft official vscode-server-linux-x64-web (no fork)
  ✓ HTTPS/TLS via nginx + self-signed certs
  ✓ HTTP redirect on ports 8440-8442 → HTTPS
  ✓ Mint-proxy for ServerKeyedAESCrypto token encryption
  ✓ Persistent volumes for extensions, config, server data

EOF
}

main() {
    [[ $# -eq 0 ]] && { show_usage; exit 1; }
    validate_environment

    local command=$1; shift

    case "$command" in
        build)
            build_image
            ;;
        create)
            [[ $# -lt 2 ]] && { print_error "Usage: $0 create <session_number> <workspace_path> [cert_dir]"; exit 1; }
            create_session "$1" "$2" "${3:-}"
            ;;
        list)
            list_sessions
            ;;
        token)
            [[ $# -lt 1 ]] && { print_error "Usage: $0 token <session_number>"; exit 1; }
            token_session "$1"
            ;;
        stop)
            [[ $# -lt 1 ]] && { print_error "Usage: $0 stop <session_number>"; exit 1; }
            stop_session "$1"
            ;;
        remove)
            [[ $# -lt 1 ]] && { print_error "Usage: $0 remove <session_number>"; exit 1; }
            remove_session "$1"
            ;;
        purge)
            [[ $# -lt 1 ]] && { print_error "Usage: $0 purge <session_number>"; exit 1; }
            purge_session "$1"
            ;;
        *)
            print_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
