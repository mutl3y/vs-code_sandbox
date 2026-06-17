#!/bin/bash
# ============================================================================
# VS Code Launcher — Single script for production and dev sessions
# ============================================================================
# Production:  ./scripts/launcher.sh build / create / update / ...
# Dev:         ./scripts/launcher.sh dev build / dev create / dev update / ...
# Promote:     ./scripts/launcher.sh dev promote (dev image → production tags)
#
# Dev mode uses isolated container names, ports, and volumes so it never
# collides with active production sessions.
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

# ── Mode defaults (production) ──────────────────────────────────────────────
DEV_MODE=false
CONTAINER_PREFIX="vscode-ssl-v2"
VOLUME_PREFIX="vscode-ssl-v2"
IMAGE_NAME="vscode-agent:default"
BASE_PORT=8550
VSCODE_BASE_PORT=9200

# ── Shared constants ─────────────────────────────────────────────────────────
PROXY_OFFSET=100
MAX_SESSIONS=3

print_header() {
    local tag=""
    [[ "$DEV_MODE" == "true" ]] && tag="[DEV] "
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  ${tag}$1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
}

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error()   { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_info()    { echo -e "${BLUE}ℹ${NC} $1"; }

container_name()  { echo "${CONTAINER_PREFIX}-${1}"; }
volume_name()     { echo "${VOLUME_PREFIX}-${1}-${2}"; }
session_port()    { echo $((BASE_PORT + ${1} - 1)); }
session_vs_port() { echo $((VSCODE_BASE_PORT + ${1} - 1)); }

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
    local user_uid=$(id -u)
    local user_gid=$(id -g)
    local tag_label="production"
    [[ "$DEV_MODE" == "true" ]] && tag_label="dev"

    print_header "Building ${tag_label} Image"
    print_info "Building ${IMAGE_NAME} with USER_UID=${user_uid} USER_GID=${user_gid}"

    $CONTAINER_CMD build \
        --build-arg USER_UID="${user_uid}" \
        --build-arg USER_GID="${user_gid}" \
        -f "${PROJECT_DIR}/Dockerfile" \
        -t "${IMAGE_NAME}" \
        "${PROJECT_DIR}" || { print_error "Build failed"; exit 1; }

    print_success "Image built: ${IMAGE_NAME}"
}

promote_image() {
    if ! $CONTAINER_CMD image inspect vscode-agent:dev &>/dev/null; then
        print_error "No dev image found. Run: $0 dev build"
        exit 1
    fi

    print_header "Promoting Dev Image → Production Tags"
    $CONTAINER_CMD tag vscode-agent:dev vscode-agent:default
    $CONTAINER_CMD tag vscode-agent:dev vscode-agent:stable
    $CONTAINER_CMD tag vscode-agent:dev vscode-agent:ssl-v2
    $CONTAINER_CMD tag vscode-agent:dev vscode-agent:latest
    print_success "Promoted vscode-agent:dev → default, stable, ssl-v2, latest"
    print_info "Run '$0 update <n>' to apply to a production session"
}

create_session() {
    local session_num=${1:?Usage: $0 [dev] create <n> <workspace_path> [cert_dir]}
    local workspace_path=${2:?Usage: $0 [dev] create <n> <workspace_path> [cert_dir]}
    local cert_dir=${3:-${CA_DIR}}

    [[ "$session_num" -lt 1 || "$session_num" -gt $MAX_SESSIONS ]] && { print_error "Session must be 1-${MAX_SESSIONS}"; exit 1; }

    local cname=$(container_name "$session_num")
    local ssl_port=$(session_port "$session_num")
    local http_port=$((ssl_port - 110))
    local vs_port=$(session_vs_port "$session_num")
    local proxy_port=$((vs_port + PROXY_OFFSET))
    local cert="${cert_dir}/server.crt" key="${cert_dir}/server.key"

    [[ -f "$cert" && -f "$key" ]] || { print_error "Certs not found: $cert / $key"; print_info "Generate with: bash ca/gen-cert.sh ca/ vscode-server"; exit 1; }

    if ! $CONTAINER_CMD image inspect "${IMAGE_NAME}" &>/dev/null; then
        print_error "Image not found. Run: $0 [dev] build"
        exit 1
    fi

    # Remove existing container if present
    $CONTAINER_CMD ps -a --filter "name=^${cname}$" --format '{{.Names}}' | grep -q "${cname}" && $CONTAINER_CMD rm -f "${cname}" &>/dev/null

    print_header "Creating Session ${session_num}"
    print_info "Port: ${ssl_port} (HTTPS)  ${http_port} (HTTP→redirect)  |  Workspace: ${workspace_path}"

    local token_vol="${VOLUME_PREFIX}-token-shared"
    $CONTAINER_CMD run -d \
        --name "${cname}" \
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
        -v "$(volume_name extensions "$session_num"):/home/vscode/.vscode-server/extensions:rw" \
        -v "$(volume_name server-data "$session_num"):/home/vscode/.vscode-server/data:rw" \
        -v "$(volume_name config "$session_num"):/home/vscode/.config:rw" \
        -v "${token_vol}:/home/vscode/.token-store:rw" \
        -v "${HOME}/.config/gh:/home/vscode/.config/gh-host:ro,z" \
        "${IMAGE_NAME}"

    print_info "Waiting for startup..."
    local retries=0
    while [[ $retries -lt 20 ]]; do
        $CONTAINER_CMD exec "${cname}" test -f /home/vscode/.vscode-token 2>/dev/null && break
        retries=$((retries + 1))
        sleep 1
    done

    local token=$($CONTAINER_CMD exec "${cname}" cat /home/vscode/.vscode-token 2>/dev/null || echo "UNKNOWN")
    local host_ip=$(hostname -I | awk '{print $1}')
    [[ -z "$host_ip" ]] && host_ip="127.0.0.1"

    print_success "Session ${session_num} ready"
    echo ""
    echo -e "  ${BLUE}URL:${NC}        https://${host_ip}:${ssl_port}/?tkn=${token}&folder=/workspace"
    echo -e "  ${BLUE}Container:${NC}   ${cname}"
    echo -e "  ${BLUE}Image:${NC}       ${IMAGE_NAME}"
    echo -e "  ${BLUE}Workspace:${NC}   ${workspace_path}"
    echo ""
}

list_sessions() {
    print_header "Active Sessions"
    local found=0 host_ip=$(hostname -I | awk '{print $1}')
    [[ -z "$host_ip" ]] && host_ip="127.0.0.1"

    for n in $(seq 1 $MAX_SESSIONS); do
        local cname=$(container_name "$n") ssl_port=$(session_port "$n")
        if $CONTAINER_CMD ps --filter "name=^${cname}$" --format '{{.Names}}' 2>/dev/null | grep -q "${cname}"; then
            local token=$($CONTAINER_CMD exec "${cname}" cat /home/vscode/.vscode-token 2>/dev/null || echo "UNKNOWN")
            echo -e "  ${GREEN}●${NC} ${cname}  https://${host_ip}:${ssl_port}/?tkn=${token}&folder=/workspace"
            found=$((found + 1))
        fi
    done
    [[ $found -eq 0 ]] && print_info "No active sessions"
}

token_session() {
    local session_num=${1:?Usage: $0 [dev] token <n>}
    local cname=$(container_name "$session_num") ssl_port=$(session_port "$session_num")
    local token=$($CONTAINER_CMD exec "${cname}" cat /home/vscode/.vscode-token 2>/dev/null) || { print_error "Container not running"; exit 1; }
    local host_ip=$(hostname -I | awk '{print $1}')
    [[ -z "$host_ip" ]] && host_ip="127.0.0.1"
    echo "https://${host_ip}:${ssl_port}/?tkn=${token}&folder=/workspace"
}

stop_session() {
    local session_num=${1:?Usage: $0 [dev] stop <n>}
    local cname=$(container_name "$session_num")
    $CONTAINER_CMD stop "${cname}" 2>/dev/null && print_success "Stopped" || print_error "Failed"
}

update_session() {
    local session_num=${1:?Usage: $0 [dev] update <n>}
    [[ "$session_num" -lt 1 || "$session_num" -gt $MAX_SESSIONS ]] && { print_error "Session must be 1-${MAX_SESSIONS}"; exit 1; }

    local cname=$(container_name "$session_num")

    # Get workspace path from the running or stopped container
    local workspace_path=""
    workspace_path=$($CONTAINER_CMD inspect "${cname}" --format '{{range .Mounts}}{{if eq .Destination "/workspace"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || echo "")

    if [[ -z "$workspace_path" ]]; then
        print_error "Could not determine workspace path for session ${session_num}"
        return 1
    fi

    print_header "Updating Session ${session_num}"
    print_info "Workspace: ${workspace_path}"
    print_info "Stopping container..."
    $CONTAINER_CMD stop "${cname}" 2>/dev/null || true

    print_info "Removing container (volumes preserved)..."
    $CONTAINER_CMD rm -f "${cname}" 2>/dev/null || true

    # Dev update rebuilds; production update just recreates
    if [[ "$DEV_MODE" == "true" ]]; then
        print_info "Rebuilding image..."
        build_image
    fi

    print_info "Recreating session with latest image..."
    create_session "$session_num" "$workspace_path"

    print_success "Session ${session_num} updated"
}

remove_session() {
    local session_num=${1:?Usage: $0 [dev] remove <n>}
    local cname=$(container_name "$session_num")
    print_warning "Remove container ${cname}? (volumes preserved)"
    read -p "(y/N) " -n 1 -r && echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { print_info "Cancelled"; return; }
    $CONTAINER_CMD rm -f "${cname}" 2>/dev/null && print_success "Removed" || print_error "Failed"
}

purge_session() {
    local session_num=${1:?Usage: $0 [dev] purge <n>}
    local cname=$(container_name "$session_num")
    print_warning "PURGE session ${session_num}? Removes container AND all volumes."
    read -p "Type 'yes' to confirm: " -r && echo
    [[ "$REPLY" != "yes" ]] && { print_info "Cancelled"; return; }
    $CONTAINER_CMD rm -f "${cname}" 2>/dev/null || true
    for vol in extensions server-data config; do
        $CONTAINER_CMD volume rm "$(volume_name "$vol" "$session_num")" 2>/dev/null && print_success "Removed volume: $(volume_name "$vol" "$session_num")" || true
    done
    $CONTAINER_CMD volume rm "${VOLUME_PREFIX}-token-shared" 2>/dev/null || true
    print_success "Session ${session_num} purged"
}

show_usage() {
    local tag="Production"
    local ports="8550-8552"
    if [[ "$DEV_MODE" == "true" ]]; then
        tag="Dev"
        ports="8560-8562"
    fi

    cat << EOF
╔════════════════════════════════════════════════════════════╗
║  [${tag}] VS Code Launcher                                      ║
╚════════════════════════════════════════════════════════════╝

QUICK START:
  1. Generate certs:    bash ca/gen-cert.sh ca/ vscode-server
  2. Build image:       ./scripts/launcher.sh [dev] build
  3. Create session:    ./scripts/launcher.sh [dev] create 1 /workspace
  4. Access:            https://127.0.0.1:$(session_port 1)/?tkn=<token>&folder=/workspace

COMMANDS:
  build                    Build image
  create  <n> <path>       Create session (n=1-3)
  update  <n>              Update session (preserves extensions/settings)
  list                     List active sessions with URLs
  token   <n>              Print access URL for session n
  stop    <n>              Stop session (volumes preserved)
  remove  <n>              Remove container (volumes preserved)
  purge   <n>              Remove container AND all volumes (clean slate)

EXTRA (dev only):
  dev promote              Promote dev image → production tags

PORTS: ${ports}

WORKFLOW (test with dev, deploy to production):
  1. ./scripts/launcher.sh dev build     # build + test with dev session
  2. ./scripts/launcher.sh dev create 1 /path/to/project
  3. ./scripts/launcher.sh dev promote   # tag dev image as production
  4. ./scripts/launcher.sh update 1      # apply to production session
EOF
}

main() {
    [[ $# -eq 0 ]] && { show_usage; exit 1; }
    validate_environment

    # Check for "dev" subcommand
    if [[ "$1" == "dev" ]]; then
        shift
        DEV_MODE=true
        CONTAINER_PREFIX="vscode-dev"
        VOLUME_PREFIX="vscode-dev"
        IMAGE_NAME="vscode-agent:dev"
        BASE_PORT=8560
        VSCODE_BASE_PORT=9210
    fi

    [[ $# -eq 0 ]] && { show_usage; exit 1; }

    local command=$1; shift

    case "$command" in
        build)
            build_image
            ;;
        create)
            [[ $# -lt 2 ]] && { print_error "Usage: $0 [dev] create <session_number> <workspace_path> [cert_dir]"; exit 1; }
            create_session "$1" "$2" "${3:-}"
            ;;
        list)
            list_sessions
            ;;
        token)
            [[ $# -lt 1 ]] && { print_error "Usage: $0 [dev] token <session_number>"; exit 1; }
            token_session "$1"
            ;;
        stop)
            [[ $# -lt 1 ]] && { print_error "Usage: $0 [dev] stop <session_number>"; exit 1; }
            stop_session "$1"
            ;;
        update)
            [[ $# -lt 1 ]] && { print_error "Usage: $0 [dev] update <session_number>"; exit 1; }
            update_session "$1"
            ;;
        promote)
            [[ "$DEV_MODE" == "true" ]] || { print_error "promote is only available in dev mode: $0 dev promote"; exit 1; }
            promote_image
            ;;
        remove)
            [[ $# -lt 1 ]] && { print_error "Usage: $0 [dev] remove <session_number>"; exit 1; }
            remove_session "$1"
            ;;
        purge)
            [[ $# -lt 1 ]] && { print_error "Usage: $0 [dev] purge <session_number>"; exit 1; }
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
