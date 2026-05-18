#!/bin/bash
# ============================================================================
# VS Code Multi-Session Launcher (Simplified - code-server)
# ============================================================================
# Launch isolated VS Code Server sessions for agent execution
# Each session: independent container, isolated workspace, persistent settings
# ============================================================================

set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
MAGENTA=$'\033[0;35m'
NC=$'\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"
BASE_PORT=8443

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
        COMPOSE_CMD="podman-compose"
        print_info "Using podman"
    elif command -v docker &> /dev/null; then
        CONTAINER_CMD="docker"
        COMPOSE_CMD="docker-compose"
        print_info "Using docker"
    else
        print_error "Neither podman nor docker found. Please install one."
        exit 1
    fi

    print_info "Using $COMPOSE_CMD"
    print_success "Environment validated"
}

create_session() {
    local SESSION_ID=$1
    local WORKSPACE_PATH=$2
    local PASSWORD=${3:-dev-session-${SESSION_ID}}

    print_header "Creating Session ${SESSION_ID}"

    # Resolve absolute path
    if [[ ! "$WORKSPACE_PATH" = /* ]]; then
        WORKSPACE_PATH="$(cd "$WORKSPACE_PATH" 2>/dev/null && pwd)" || {
            print_error "Workspace path not found: $2"
            exit 1
        }
    fi

    print_info "Workspace: $WORKSPACE_PATH"
    print_info "Password: $PASSWORD"

    # Set up worktrees directory
    WORKTREES_PATH="${WORKSPACE_PATH}.worktrees"
    mkdir -p "$WORKTREES_PATH"

    # Calculate port for this session
    SESSION_PORT=$((BASE_PORT + SESSION_ID - 1))

    print_info "Starting container for session-${SESSION_ID} on port ${SESSION_PORT}..."

    # Export environment for docker-compose substitution
    export WORKSPACE_PATH_SESSION_${SESSION_ID}="${WORKSPACE_PATH}"
    export WORKTREES_PATH_SESSION_${SESSION_ID}="${WORKTREES_PATH}"
    export CODE_SERVER_PASSWORD="${PASSWORD}"
    export PORT_SESSION_${SESSION_ID}="${SESSION_PORT}"

    # Use docker-compose up with proper environment variable export
    $COMPOSE_CMD -f "$COMPOSE_FILE" \
        up -d \
        --no-deps \
        "vscode-session-${SESSION_ID}" 2>&1 || {
        print_error "Failed to start container"
        exit 1
    }

    print_success "Container started: vscode-session-${SESSION_ID}"

    # Wait for startup
    print_info "Waiting for server startup..."
    sleep 3

    # Check if container is actually running
    if ! $CONTAINER_CMD inspect "vscode-session-${SESSION_ID}" &> /dev/null; then
        print_error "Container failed to start - checking logs:"
        $CONTAINER_CMD logs "vscode-session-${SESSION_ID}" || true
        exit 1
    fi

    print_success "Session ${SESSION_ID} is running"
    echo ""
    echo -e "${MAGENTA}✨ Connection Information${NC}"
    echo -e "${MAGENTA}════════════════════════════════════════════════════════${NC}"
    echo -e "Session ID:    ${MAGENTA}${SESSION_ID}${NC}"
    echo -e "Password:      ${MAGENTA}${PASSWORD}${NC}"
    echo -e "Workspace:     ${MAGENTA}${WORKSPACE_PATH}${NC}"
    echo -e "Worktrees:     ${MAGENTA}${WORKTREES_PATH}${NC}"
    echo ""
    echo -e "${YELLOW}Access URL:${NC}"
    echo -e "  ${BLUE}http://localhost:${SESSION_PORT}/?folder=/workspace${NC}"
    echo -e "  ${BLUE}http://127.0.0.1:${SESSION_PORT}/?folder=/workspace${NC}"
    echo ""
    echo -e "${YELLOW}Quick Access:${NC}"
    echo -e "  Password will be saved in session after first login"
    echo ""
}

delete_session() {
    local SESSION_ID=$1

    print_header "Deleting Session ${SESSION_ID}"

    print_info "Stopping container..."
    $CONTAINER_CMD rm -f "vscode-session-${SESSION_ID}" 2>&1 || true

    print_success "Session ${SESSION_ID} deleted"
}

logs_session() {
    local SESSION_ID=$1

    print_header "Logs for Session ${SESSION_ID}"

    $CONTAINER_CMD logs -f "vscode-session-${SESSION_ID}"
}

usage() {
    cat << 'EOF'
VS Code Multi-Session Launcher (Simplified)

USAGE:
  ./launcher.sh create <session_id> <workspace_path> [password]
  ./launcher.sh delete <session_id>
  ./launcher.sh logs <session_id>

EXAMPLES:
  # Create session 1 with auto-generated password
  ./launcher.sh create 1 /path/to/workspace

  # Create session 1 with custom password
  ./launcher.sh create 1 /path/to/workspace mypassword

  # View logs for session 1
  ./launcher.sh logs 1

  # Delete session 1
  ./launcher.sh delete 1

ACCESSING THE SERVER:
  1. Run: ./launcher.sh create 1 /path/to/workspace
  2. Open: http://<your-host-ip>:8080
  3. Enter password when prompted
  4. VS Code opens in browser

PORTS:
  - Session 1: port 8080
  - Session 2: port 8081
  - Session 3: port 8082
  - etc.

EOF
}

# Main
case "${1:-}" in
    create)
        if [[ $# -lt 3 ]]; then
            print_error "Usage: ./launcher.sh create <session_id> <workspace_path> [password]"
            exit 1
        fi
        validate_environment
        create_session "$2" "$3" "${4:-}"
        ;;
    delete)
        if [[ $# -lt 2 ]]; then
            print_error "Usage: ./launcher.sh delete <session_id>"
            exit 1
        fi
        validate_environment
        delete_session "$2"
        ;;
    logs)
        if [[ $# -lt 2 ]]; then
            print_error "Usage: ./launcher.sh logs <session_id>"
            exit 1
        fi
        validate_environment
        logs_session "$2"
        ;;
    build)
        validate_environment
        print_header "Building VS Code Server Image"
        $COMPOSE_CMD -f "$COMPOSE_FILE" build
        ;;
    *)
        usage
        exit 1
        ;;
esac
