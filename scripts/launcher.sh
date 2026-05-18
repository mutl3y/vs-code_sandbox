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
BASE_PORT=8443
# SSL sessions use ports 8540+ to avoid colliding with HTTP sessions (8443-8445)
SSL_BASE_PORT=8540
# Internal VS Code port per SSL session (loopback only)
SSL_VSCODE_BASE_PORT=9100
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

    print_success "Environment validated"
}

list_sessions() {
    print_header "Active VS Code Sessions"

    local sessions=$($CONTAINER_CMD ps --filter "name=vscode-session-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null)

    if [ -z "$sessions" ]; then
        print_info "No active sessions found"
        return
    fi

    echo "$sessions"
}

build_image() {
    print_header "Building VS Code Agent Image"

    if $CONTAINER_CMD image inspect vscode-agent:latest &> /dev/null; then
        print_success "Image already exists (vscode-agent:latest)"
        return
    fi

    local user_uid
    local user_gid
    user_uid=$(id -u)
    user_gid=$(id -g)
    print_info "Building image with USER_UID=${user_uid} USER_GID=${user_gid}..."
    $CONTAINER_CMD build \
        --build-arg USER_UID="${user_uid}" \
        --build-arg USER_GID="${user_gid}" \
        -f "${PROJECT_DIR}/Dockerfile" \
        -t vscode-agent:latest \
        "${PROJECT_DIR}"

    print_success "Image built successfully"
}

create_session() {
    local session_num=$1
    local workspace_path=$2
    local custom_password=${3:-}  # Optional custom password

    print_header "Creating Session $session_num"

    if [ "$session_num" -lt 1 ] || [ "$session_num" -gt 3 ]; then
        print_error "Session number must be 1-3"
        exit 1
    fi

    # Prepare host-mounted home directory with proper permissions
    local home_config_dir="$HOME/.vscode-container-session-$session_num"
    print_info "Preparing persistent config directory: $home_config_dir"
    mkdir -p "$home_config_dir"/{.config/code-server,.local/share/code-server}
    chmod 755 "$home_config_dir" 2>/dev/null || true
    chmod 755 "$home_config_dir/.config" 2>/dev/null || true
    chmod 755 "$home_config_dir/.config/code-server" 2>/dev/null || true
    chmod 755 "$home_config_dir/.local" 2>/dev/null || true
    chmod 755 "$home_config_dir/.local/share" 2>/dev/null || true
    chmod 755 "$home_config_dir/.local/share/code-server" 2>/dev/null || true

    if [ ! -d "$workspace_path" ]; then
        print_info "Creating workspace directory: $workspace_path"
        mkdir -p "$workspace_path"
        chmod 777 "$workspace_path" 2>/dev/null || true
    fi

    local worktree_path="${workspace_path%/}.worktrees"
    if [ ! -d "$worktree_path" ]; then
        mkdir -p "$worktree_path"
        chmod 777 "$worktree_path" 2>/dev/null || true
    fi

    local port=$((BASE_PORT + session_num - 1))

    print_info "Starting container for session-$session_num..."

    # Export paths as environment variables for compose substitution
    export WORKSPACE_PATH_SESSION_${session_num}="$workspace_path"
    export WORKTREES_PATH_SESSION_${session_num}="$worktree_path"
    export PORT_SESSION_${session_num}="$port"

    $COMPOSE_CMD -f "$COMPOSE_FILE" up -d "vscode-session-$session_num"

    if [ $? -ne 0 ]; then
        print_error "Failed to start session $session_num"
        exit 1
    fi

    print_info "Waiting for container startup..."
    sleep 5

    local port=$((BASE_PORT + session_num - 1))
    local max_retries=30
    local retry=0
    while [ $retry -lt $max_retries ]; do
        if curl -sf "http://127.0.0.1:${port}/" &> /dev/null; then
            break
        fi
        retry=$((retry + 1))
        sleep 1
    done

    # Handle password: use custom if provided, otherwise read from config
    local password="$custom_password"

    if [ -z "$password" ]; then
        # Read the auto-generated password from code-server config with retry logic
        local pw_retries=0
        local pw_max_retries=10
        while [ $pw_retries -lt $pw_max_retries ] && [ -z "$password" ]; do
            password=$($CONTAINER_CMD exec "vscode-session-$session_num" grep "^password:" /home/vscode/.config/code-server/config.yaml 2>/dev/null | cut -d' ' -f2 || echo "")
            if [ -n "$password" ]; then
                break
            fi
            pw_retries=$((pw_retries + 1))
            sleep 0.5
        done

        if [ -z "$password" ]; then
            password="UNKNOWN"
        fi
    else
        # Update config-server config with custom password
        print_info "Setting custom password..."
        $CONTAINER_CMD exec "vscode-session-$session_num" bash -c "
            sed -i \"s/^password: .*/password: $custom_password/\" /home/vscode/.config/code-server/config.yaml
        " || print_warning "Failed to set custom password"
    fi

    # Generate auto-login link
    local links_dir="${PROJECT_DIR}/links"
    mkdir -p "$links_dir"
    local link_file="${links_dir}/session-${session_num}-autologin.html"

    # Detect host IP (use first non-loopback IP)
    local host_ip=$(hostname -I | awk '{print $1}')
    if [ -z "$host_ip" ]; then
        host_ip="localhost"
    fi

    if [ "$password" != "UNKNOWN" ]; then
        cat > "$link_file" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>VS Code Session $session_num - Auto-Login</title>
    <meta charset="UTF-8">
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 40px; background: #1e1e1e; color: #d4d4d4; }
        .container { max-width: 600px; margin: 0 auto; }
        h1 { color: #4fc3f7; }
        .info { background: #252526; padding: 20px; border-radius: 8px; margin: 20px 0; }
        .status { padding: 12px; margin: 20px 0; border-radius: 4px; text-align: center; font-weight: bold; }
        .success { background: #4caf50; color: white; }
        .loading { background: #ff9800; color: white; }
        code { background: #333; padding: 2px 6px; border-radius: 3px; font-family: 'Courier New', monospace; word-break: break-all; }
        p { line-height: 1.8; }
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 VS Code Session Auto-Login</h1>
        <div id="status" class="status loading">🔄 Connecting to session...</div>

        <div class="info">
            <p><strong>Session:</strong> <code>Session $session_num</code></p>
            <p><strong>Host:</strong> <code>https://$host_ip:$port</code></p>
            <p><strong>Password:</strong> <code>${password:0:8}***</code></p>
            <p><strong>Status:</strong> <span id="connect-status">Initializing...</span></p>
            <p style="font-size: 0.9em; color: #888;">🔒 Secured with TLS</p>
        </div>
    </div>

    <script>
        const sessionNum = '$session_num';
        const password = '$password';
        const hostIp = '$host_ip';
        const port = '$port';
        const url = \`https://\${hostIp}:\${port}\`;

        console.log('Auto-login initializing...', { sessionNum, port });

        function attempt_login() {
            document.getElementById('connect-status').textContent = 'Connecting to secure session (please accept certificate warning if prompted)...';
            // Give browser time to load the page naturally
            // This allows users to accept self-signed cert warning if needed
            setTimeout(() => {
                window.location.href = url + '/login';
            }, 1500);
        }

        function attempt_password_submit() {
            document.getElementById('connect-status').textContent = 'Attempting password submission...';
            const iframe = document.createElement('iframe');
            iframe.style.display = 'none';
            iframe.src = url + '/login';
            document.body.appendChild(iframe);

            iframe.onload = () => {
                try {
                    const doc = iframe.contentDocument || iframe.contentWindow.document;
                    const passwordInput = doc.querySelector('input[type="password"]');

                    if (passwordInput) {
                        passwordInput.value = password;
                        const submitBtn = doc.querySelector('button[type="submit"]') || doc.querySelector('button');
                        if (submitBtn) {
                            document.getElementById('status').textContent = '✅ Logging in...';
                            document.getElementById('status').className = 'status success';
                            document.getElementById('connect-status').textContent = 'Password submitted, redirecting...';
                            submitBtn.click();
                            setTimeout(() => {
                                window.location.href = url + '/';
                            }, 800);
                        } else {
                            document.getElementById('connect-status').textContent = 'Could not find submit button, redirecting...';
                            setTimeout(() => {
                                window.location.href = url + '/';
                            }, 1000);
                        }
                    } else {
                        document.getElementById('connect-status').textContent = 'Session already authenticated, opening...';
                        window.location.href = url + '/';
                    }
                } catch (e) {
                    console.error('CORS or frame access error (expected):', e.message);
                    // Self-signed cert or CORS issue - redirect directly
                    document.getElementById('connect-status').textContent = 'Redirecting to session...';
                    setTimeout(() => {
                        window.location.href = url + '/';
                    }, 500);
                }
            };

            iframe.onerror = () => {
                document.getElementById('connect-status').textContent = 'Redirecting to session...';
                setTimeout(() => {
                    window.location.href = url + '/';
                }, 500);
            };
        }

        attempt_login();
    </script>
</body>
</html>
EOF
        chmod 644 "$link_file"
    fi

    print_success "Session $session_num created successfully"
    print_info "Session Details:"
    echo -e "  ${BLUE}Container:${NC}   vscode-session-$session_num"
    echo -e "  ${BLUE}URL:${NC}         https://$host_ip:$port"
    echo -e "  ${BLUE}Password:${NC}    $password"
    echo -e "  ${BLUE}Workspace:${NC}   $workspace_path"
    echo -e "  ${BLUE}Worktrees:${NC}   $worktree_path"

    if [ "$password" != "UNKNOWN" ]; then
        echo -e "\n${GREEN}✨ Quick Access:${NC}"
        echo -e "  ${BLUE}Auto-login link:${NC} $link_file"
        echo -e "  ${BLUE}Direct URL:${NC}    https://$host_ip:$port#password=$password"
        echo -e "\n${YELLOW}🔒 Secured with TLS - Password transmitted over HTTPS${NC}"
        echo -e "  Or manually:   https://$host_ip:$port + password: $password"
    fi
}

stop_session() {
    local session_num=$1
    print_info "Stopping session $session_num..."

    $COMPOSE_CMD -f "$COMPOSE_FILE" stop "vscode-session-$session_num" 2>/dev/null

    if [ $? -eq 0 ]; then
        print_success "Session $session_num stopped"
    else
        print_error "Failed to stop session $session_num"
        exit 1
    fi
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
# SSL session management (podman run direct, no compose)
# Images: vscode-agent:ssl  Ports: 8540, 8541, 8542
# ============================================================================

ssl_build_image() {
    print_header "Building VS Code SSL Image"
    if podman image inspect vscode-agent:ssl &>/dev/null; then
        print_success "Image already exists (vscode-agent:ssl)"
        return
    fi
    # Ensure base image exists first
    if ! $CONTAINER_CMD image inspect vscode-agent:latest &>/dev/null; then
        print_info "Base image not found — building vscode-agent:latest first..."
        build_image
    fi
    print_info "Building vscode-agent:ssl (layers on vscode-agent:latest)..."
    $CONTAINER_CMD build -f "${PROJECT_DIR}/Dockerfile.ssl" -t vscode-agent:ssl "${PROJECT_DIR}"
    print_success "Image built: vscode-agent:ssl"
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

    if ! podman image inspect vscode-agent:ssl &>/dev/null; then
        print_error "Image vscode-agent:ssl not found. Run: $0 ssl-build"
        exit 1
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
    local token_vol="vscode-ssl-token-shared"
    print_info "Extensions: ${ext_vol} (named volume, survives ssl-remove)"
    print_info "Token:      ${token_vol} (shared across all SSL sessions)"

    podman run -d \
        --name "${container_name}" \
        --network=host \
        --userns=keep-id \
        -e SSL_PORT="${ssl_port}" \
        -e VSCODE_PORT="${vs_port}" \
        -e WORKSPACE_DIR="/workspace" \
        -v "${cert}:/etc/nginx/ssl/server.crt:ro" \
        -v "${key}:/etc/nginx/ssl/server.key:ro" \
        -v "${workspace_path}:/workspace:rw" \
        -v "${ext_vol}:/home/vscode/.vscode-server/extensions:rw" \
        -v "${token_vol}:/home/vscode/.token-store:rw" \
        vscode-agent:ssl

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
    print_warning "This will remove container ${container_name} (extensions volume preserved)"
    read -p "Are you sure? (y/N) " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { print_info "Cancelled"; return; }
    podman rm -f "${container_name}" 2>/dev/null && print_success "${container_name} removed (extensions in vscode-ssl-extensions-${session_num})" || print_error "Failed to remove ${container_name}"
}

ssl_purge_session() {
    local session_num=$1
    local container_name="vscode-ssl-${session_num}"
    local ext_vol="vscode-ssl-extensions-${session_num}"
    print_warning "This will remove container ${container_name} and its extensions volume (irreversible)"
    print_info  "Shared token volume is preserved unless all sessions are purged"
    read -p "Are you sure? (y/N) " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { print_info "Cancelled"; return; }
    podman rm -f "${container_name}" 2>/dev/null || true
    if podman volume inspect "${ext_vol}" &>/dev/null; then
        podman volume rm "${ext_vol}" && print_success "${ext_vol} removed" || print_error "Failed to remove ${ext_vol}"
    else
        print_info "Volume ${ext_vol} does not exist"
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

Usage: $0 <command> [options]

HTTP Sessions (image: vscode-agent:latest, no auth):
  ${GREEN}build${NC}                              Build the HTTP base image
  ${GREEN}create${NC} <session> <path> [pwd]    Create session (sessions 1-3, ports 8443-8445)
  ${GREEN}start${NC} <session>                  Start an existing session
  ${GREEN}stop${NC} <session>                   Stop a running session
  ${GREEN}rotate-password${NC} <session> <pwd>  Rotate password for a session
  ${GREEN}remove${NC} <session>                 Remove session container (volumes preserved)
  ${GREEN}purge${NC} <session>                  Remove session container AND config volumes
  ${GREEN}list${NC}                             List active HTTP sessions
  ${GREEN}logs${NC} <session>                   Show container logs

SSL Sessions (image: vscode-agent:ssl, token auth, TLS via nginx):
  ${GREEN}ssl-build${NC}                                   Build the SSL image
  ${GREEN}ssl-create${NC} <session> <path> [cert_dir]    Create SSL session (ports 8540-8542)
  ${GREEN}ssl-stop${NC} <session>                         Stop SSL session
  ${GREEN}ssl-remove${NC} <session>                       Remove container (extensions volume preserved)
  ${GREEN}ssl-purge${NC} <session>                        Remove container AND extensions volume
  ${GREEN}ssl-list${NC}                                   List active SSL sessions (with token URLs)
  ${GREEN}ssl-token${NC} <session>                        Print access URL for SSL session

Examples:
  $0 ssl-build
  $0 ssl-create 1 /path/to/workspace              # Uses ca/ certs by default
  $0 ssl-create 1 /path/to/workspace /my/certs    # Custom cert dir
  $0 ssl-list
  $0 ssl-token 1
  $0 ssl-stop 1

HTTP Ports:  Session 1=8443  Session 2=8444  Session 3=8445
SSL Ports:   Session 1=8540  Session 2=8541  Session 3=8542
Cert dir:    ${PROJECT_DIR}/ca/ (server.crt + server.key)

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
        create)
            if [ $# -lt 2 ]; then
                print_error "Usage: $0 create <session_number> <workspace_path> [password]"
                exit 1
            fi
            create_session "$1" "$2" "${3:-}"
            ;;
        start)
            if [ $# -lt 1 ]; then
                print_error "Usage: $0 start <session_number>"
                exit 1
            fi
            print_info "Starting session $1..."
            $COMPOSE_CMD -f "$COMPOSE_FILE" up -d "vscode-session-$1"
            print_success "Session $1 started"
            ;;
        stop)
            if [ $# -lt 1 ]; then
                print_error "Usage: $0 stop <session_number>"
                exit 1
            fi
            stop_session "$1"
            ;;
        rotate-password)
            if [ $# -lt 2 ]; then
                print_error "Usage: $0 rotate-password <session_number> <new_password>"
                exit 1
            fi
            rotate_password "$1" "$2"
            ;;
        remove)
            if [ $# -lt 1 ]; then
                print_error "Usage: $0 remove <session_number>"
                exit 1
            fi
            remove_session "$1"
            ;;
        purge)
            if [ $# -lt 1 ]; then
                print_error "Usage: $0 purge <session_number>"
                exit 1
            fi
            purge_session "$1"
            ;;
        list)
            list_sessions
            ;;
        ssl-build)
            ssl_build_image
            ;;
        ssl-create)
            if [[ $# -lt 2 ]]; then
                print_error "Usage: $0 ssl-create <session_number> <workspace_path> [cert_dir]"
                exit 1
            fi
            ssl_create_session "$1" "$2" "${3:-}"
            ;;
        ssl-stop)
            [[ $# -lt 1 ]] && { print_error "Usage: $0 ssl-stop <session_number>"; exit 1; }
            ssl_stop_session "$1"
            ;;
        ssl-remove)
            [[ $# -lt 1 ]] && { print_error "Usage: $0 ssl-remove <session_number>"; exit 1; }
            ssl_remove_session "$1"
            ;;
        ssl-purge)
            [[ $# -lt 1 ]] && { print_error "Usage: $0 ssl-purge <session_number>"; exit 1; }
            ssl_purge_session "$1"
            ;;
        ssl-list)
            ssl_list_sessions
            ;;
        ssl-token)
            [[ $# -lt 1 ]] && { print_error "Usage: $0 ssl-token <session_number>"; exit 1; }
            ssl_token_session "$1"
            ;;
        logs)
            if [ $# -lt 1 ]; then
                print_error "Usage: $0 logs <session_number>"
                exit 1
            fi
            show_logs "$1"
            ;;
        *)
            print_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
