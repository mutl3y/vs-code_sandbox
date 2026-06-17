#!/bin/bash
# ============================================================================
# VS Code Dev Launcher — Isolated from production launcher
# ============================================================================
# Uses DIFFERENT container names, port ranges, and volume names than
# scripts/launcher.sh to ensure zero collision with active production sessions.
#
# Production (DO NOT TOUCH):
#   Containers: vscode-ssl-v2-{1,2,3}
#   HTTPS ports: 8550-8552
#   VS Code ports: 9200-9202
#   Volumes: vscode-ssl-v2-*
#
# Dev (THIS SCRIPT):
#   Containers: vscode-dev-{1,2,3}
#   HTTPS ports: 8560-8562
#   VS Code ports: 9210-9212
#   Volumes: vscode-dev-*
# ============================================================================

set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
CA_DIR="${PROJECT_DIR}/ca"

# ── Dev-specific port ranges (never collide with production 8550-8552) ──────
DEV_BASE_PORT=8560
DEV_VSCODE_BASE_PORT=9210

print_header() {
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  [DEV] $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
}

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error()   { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_info()    { echo -e "${BLUE}ℹ${NC} $1"; }

validate_environment() {
    print_info "Validating environment..."

    if command -v podman &> /dev/null; then
        CONTAINER_CMD="podman"
    elif command -v docker &> /dev/null; then
        CONTAINER_CMD="docker"
    else
        print_error "Neither podman nor docker found"
        exit 1
    fi

    if ! $CONTAINER_CMD ps &> /dev/null; then
        print_error "Container runtime not responding"
        exit 1
    fi

    print_success "Environment validated (using ${CONTAINER_CMD})"
}

build_image() {
    print_header "Building Dev Image (no mint-proxy, no sed patches)"

    local user_uid=$(id -u)
    local user_gid=$(id -g)

    print_info "Building vscode-agent:dev with USER_UID=${user_uid} USER_GID=${user_gid}"
    print_info "  • Microsoft official vscode-server-linux-x64-web (latest stable)"
    print_info "  • HTTPS/TLS via nginx"
    print_info "  • NO mint-proxy (native vscode support)"
    print_info "  • NO sed patches (vscode:/// URIs native)"

    $CONTAINER_CMD build \
        --build-arg USER_UID="${user_uid}" \
        --build-arg USER_GID="${user_gid}" \
        -f "${PROJECT_DIR}/Dockerfile" \
        -t vscode-agent:dev \
        "${PROJECT_DIR}" || { print_error "Build failed"; exit 1; }

    print_success "Image built: vscode-agent:dev"
}

create_session() {
    local session_num=$1 workspace_path=$2 cert_dir=${3:-${CA_DIR}}

    [[ "$session_num" -lt 1 || "$session_num" -gt 3 ]] && { print_error "Session must be 1-3"; exit 1; }

    local container_name="vscode-dev-${session_num}"
    local ssl_port=$((DEV_BASE_PORT + session_num - 1))
    local http_port=$((ssl_port - 110))
    local vs_port=$((DEV_VSCODE_BASE_PORT + session_num - 1))
    local proxy_port=$((vs_port + 100))
    local cert="${cert_dir}/server.crt" key="${cert_dir}/server.key"

    [[ -f "$cert" && -f "$key" ]] || { print_error "Certs not found: $cert / $key"; print_info "Generate with: bash ca/gen-cert.sh ca/ vscode-server"; exit 1; }

    if ! $CONTAINER_CMD image inspect vscode-agent:dev &>/dev/null; then
        print_error "Image not found. Run: $0 build"
        exit 1
    fi

    # Remove existing dev container if present (safe — different name from production)
    $CONTAINER_CMD ps -a --filter "name=^${container_name}$" --format '{{.Names}}' | grep -q "${container_name}" && $CONTAINER_CMD rm -f "${container_name}" &>/dev/null

    print_header "Creating Dev Session ${session_num}"
    print_info "Port: ${ssl_port} (HTTPS)  ${http_port} (HTTP→redirect)  |  Workspace: ${workspace_path}"
    print_warning "This is an ISOLATED dev container — will not affect production sessions"

    $CONTAINER_CMD run -d \
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
        -v "vscode-dev-extensions-${session_num}:/home/vscode/.vscode-server/extensions:rw" \
        -v "vscode-dev-server-data-${session_num}:/home/vscode/.vscode-server/data:rw" \
        -v "vscode-dev-config-${session_num}:/home/vscode/.config:rw" \
        -v "vscode-dev-token-shared:/home/vscode/.token-store:rw" \
        -v "${HOME}/.config/gh:/home/vscode/.config/gh-host:ro,z" \
        "vscode-agent:dev"

    print_info "Waiting for startup..."
    local retries=0
    while [[ $retries -lt 20 ]]; do
        $CONTAINER_CMD exec "${container_name}" test -f /home/vscode/.vscode-token 2>/dev/null && break
        retries=$((retries + 1))
        sleep 1
    done

    local token=$($CONTAINER_CMD exec "${container_name}" cat /home/vscode/.vscode-token 2>/dev/null || echo "UNKNOWN")
    local host_ip=$(hostname -I | awk '{print $1}')
    [[ -z "$host_ip" ]] && host_ip="127.0.0.1"

    print_success "Dev Session ${session_num} ready"
    echo ""
    echo -e "  ${BLUE}URL:${NC}        https://${host_ip}:${ssl_port}/?tkn=${token}&folder=/workspace"
    echo -e "  ${BLUE}Container:${NC}   ${container_name}"
    echo -e "  ${BLUE}Image:${NC}       vscode-agent:dev"
    echo -e "  ${BLUE}Workspace:${NC}   ${workspace_path}"
    echo ""
}

list_sessions() {
    print_header "Active Dev Sessions"
    local found=0 host_ip=$(hostname -I | awk '{print $1}')
    [[ -z "$host_ip" ]] && host_ip="127.0.0.1"

    for n in 1 2 3; do
        local container_name="vscode-dev-${n}" ssl_port=$((DEV_BASE_PORT + n - 1))
        if $CONTAINER_CMD ps --filter "name=^${container_name}$" --format '{{.Names}}' 2>/dev/null | grep -q "${container_name}"; then
            local token=$($CONTAINER_CMD exec "${container_name}" cat /home/vscode/.vscode-token 2>/dev/null || echo "UNKNOWN")
            echo -e "  ${GREEN}●${NC} ${container_name}  https://${host_ip}:${ssl_port}/?tkn=${token}&folder=/workspace"
            found=$((found + 1))
        fi
    done
    [[ $found -eq 0 ]] && print_info "No active dev sessions"
}

token_session() {
    local session_num=$1 container_name="vscode-dev-${session_num}" ssl_port=$((DEV_BASE_PORT + session_num - 1))
    local token=$($CONTAINER_CMD exec "${container_name}" cat /home/vscode/.vscode-token 2>/dev/null) || { print_error "Container not running"; exit 1; }
    local host_ip=$(hostname -I | awk '{print $1}')
    [[ -z "$host_ip" ]] && host_ip="127.0.0.1"
    echo "https://${host_ip}:${ssl_port}/?tkn=${token}&folder=/workspace"
}

stop_session() {
    local container_name="vscode-dev-$1"
    $CONTAINER_CMD stop "${container_name}" 2>/dev/null && print_success "Stopped" || print_error "Failed"
}

remove_session() {
    local session_num=$1 container_name="vscode-dev-${session_num}"
    print_warning "Remove dev container ${container_name}? (volumes preserved)"
    read -p "(y/N) " -n 1 -r && echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { print_info "Cancelled"; return; }
    $CONTAINER_CMD rm -f "${container_name}" 2>/dev/null && print_success "Removed" || print_error "Failed"
}

purge_session() {
    local session_num=${1:?Usage: $0 purge <session_number>}
    local container_name="vscode-dev-${session_num}"
    print_warning "PURGE dev session ${session_num}? Removes container AND all dev volumes."
    read -p "Type 'yes' to confirm: " -r && echo
    [[ "$REPLY" != "yes" ]] && { print_info "Cancelled"; return; }
    $CONTAINER_CMD rm -f "${container_name}" 2>/dev/null || true
    for vol in extensions server-data config; do
        $CONTAINER_CMD volume rm "vscode-dev-${vol}-${session_num}" 2>/dev/null && print_success "Removed volume: vscode-dev-${vol}-${session_num}" || true
    done
    $CONTAINER_CMD volume rm "vscode-dev-token-shared" 2>/dev/null || true
    print_success "Dev session ${session_num} purged"
}

show_usage() {
    cat << 'EOF'
╔════════════════════════════════════════════════════════════╗
║  [DEV] VS Code Launcher — Isolated from Production        ║
╚════════════════════════════════════════════════════════════╝

ISOLATION:
  Production containers: vscode-ssl-v2-{1,2,3} (ports 8550-8552)
  Dev containers:        vscode-dev-{1,2,3}    (ports 8560-8562)
  Dev volumes:           vscode-dev-* (separate from vscode-ssl-v2-*)

QUICK START:
  1. Build dev image:    ./scripts/launcher-dev.sh build
  2. Create dev session: ./scripts/launcher-dev.sh create 1 /path/to/project
  3. Access:             https://127.0.0.1:8560/?tkn=<token>&folder=/workspace

COMMANDS:
  build                     Build vscode-agent:dev (no mint-proxy, no patches)
  create  <n> <path> [certs]  Create HTTPS session (n=1-3)
  list                      List active dev sessions
  token   <n>               Print access URL for dev session n
  stop    <n>               Stop dev session
  remove  <n>               Remove dev container (volumes preserved)
  purge   <n>               Remove container AND all dev volumes

DEFAULT DEV PORTS:  8560 (session 1)  |  8561 (session 2)  |  8562 (session 3)

WHAT'S DIFFERENT FROM PRODUCTION:
  ✓ No mint-proxy (vscode handles ServerKeyedAESCrypto natively)
  ✓ No sed patches on getCwdResource (vscode:/// URIs natively)
  ✓ No workspace-trust override settings
  ✓ All containers, volumes, and ports fully isolated from production

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
