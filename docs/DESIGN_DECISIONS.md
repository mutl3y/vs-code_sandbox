# Design Decisions and Technical Rationale

## Option 3: VS Code Server in Container

### Why This Over Other Options?

**Option 1: Remote SSH into Container**
- Pros: Orchestrator on host, terminal on SSH
- Cons: Two-tier complexity, host/container boundary management

**Option 2: Docker Exec into Agent Containers**
- Pros: Simple agent execution
- Cons: No persistent VS Code experience, ephemeral

**Option 3: VS Code Server in Container** ✅
- Pros: Full isolation, persistent settings, simple architecture, native agent execution
- Cons: Slightly larger image (~1.2 GB)

**Decision**: Option 3. Simplest for developers, best isolation, minimal orchestration overhead.

## Image Architecture: Single Dockerfile

### Why Not Multi-Stage?

Multi-stage Dockerfile with builder/runtime separation would:
- Reduce image size by ~66% (save ~800 MB)
- Separate build tools from runtime tools
- Improve security (no build tools in prod)

### Why We Chose Single Dockerfile

1. **Simplicity**: One Dockerfile, easier to maintain
2. **Full Dev Environment**: Developers inside container need git, npm, python, docker CLI (all build tools)
3. **Acceptable Size**: ~1.2 GB is reasonable for modern infrastructure
4. **Vs Code Server Overhead**: VS Code + devcontainer base is ~1 GB alone; separating doesn't help much
5. **Development Use Case**: Developers need build tools (they're not a security boundary; container is)

**Trade-off**: Slightly larger image, but much simpler to understand and modify.

## Named Volumes vs. Tmpfs

### Option A: Named Volumes (Chosen)
```yaml
vscode-session-1-data:
  driver: local  # Persists to host filesystem
```

**Pros:**
- VS Code settings survive host restart
- Backup/restore easy
- Debuggable (files on host disk)

**Cons:**
- Uses host storage (~2-3 GB per session)
- Slower than tmpfs

### Option B: Tmpfs (In-Memory)
```yaml
vscode-session-1-data:
  driver: tmpfs  # Fast, ephemeral
```

**Pros:**
- Fast I/O
- Auto-cleanup on restart

**Cons:**
- Settings lost on restart
- Host restart = lost VS Code config

**Decision**: Named volumes. VS Code data should persist across restarts; developers expect their settings to stick around.

## Resource Limits: 4 CPU, 4 GB RAM

### Why These Limits?

Typical development workload:
- Single builder task: Uses 2-3 CPU, 1.5-2 GB RAM
- Multiple tools (VS Code, npm build, Docker, tests): ~1 GB overhead
- Buffer for spikes: ~1 GB

### Why Not Higher?

- 8 CPU, 8 GB per container × 3 sessions = 24 CPU, 24 GB total (excessive for typical host)
- 4 CPU, 4 GB × 3 sessions = 12 CPU, 12 GB total (reasonable for modern workstation)

### Why Not Lower?

- Under 2 CPU: npm build throttled significantly
- Under 2 GB: npm install + VS Code + build tools = memory pressure
- Soft reservation (2 CPU, 2 GB) allows bursting but shares host resources

**Decision**: 4 CPU, 4 GB limits with 2 CPU, 2 GB soft reservation. Balances performance and resource sharing.

## Persistent Volumes: Where?

### /home/vscode/.local/share/code-server (VS Code Data)

Why mount here?
- VS Code Server stores extensions, settings, workspace metadata here
- Large data (extensions can be 100s of MB)
- Should persist across container restarts

**Volume strategy**: Named volume `vscode-session-N-data`

### /home/vscode/.config/code-server (VS Code Config)

Why separate from data?
- Keeps config separate for easier backup/restore
- Smaller size (just JSON preferences)
- Independent versioning (update one without other)

**Volume strategy**: Named volume `vscode-session-N-config`

### /home/vscode/.agent-cache (Build Cache)

Why mount?
- npm cache, build artifacts, pip cache can be >1 GB
- Persisting speeds up builds dramatically
- Saves bandwidth (don't re-download packages)

**Volume strategy**: Named volume `vscode-session-N-cache`

### /workspace (Project Files)

Why host mount (not volume)?
- Source code should be on host (for IDE, version control, backups)
- Bidirectional sync: edits in container appear on host
- Developers expect files to persist beyond container lifecycle

**Volume strategy**: Host bind mount (bidirectional)

### /worktrees (Git Worktrees)

Why host mount?
- Worktrees contain git metadata + checked-out branches
- Should be accessible by multiple containers (for merge operations)
- Needs to persist for git operations to work across sessions

**Volume strategy**: Host bind mount (bidirectional)

## Non-Root User: Why UID 1000?

### Default UID/GID in Devcontainers

```dockerfile
RUN groupadd -r vscode && useradd -r -g vscode -u 1000 -m vscode
```

**Why 1000?**
- Standard for devcontainer base images
- Host user typically gets UID 1000 (first non-system user)
- Easier file ownership mapping (container 1000 = host 1000)

**Security implications:**
- Prevents root execution
- Agents cannot escalate privileges (unless explicitly configured with sudo)
- Container compromise doesn't give host root

## Healthcheck: Why This Endpoint?

```dockerfile
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -sf http://localhost:8443/health 2>/dev/null || exit 1
```

**Why not simple PID check?**
- PID check only verifies process exists, not that it's responsive
- HTTP health check verifies:
  - Port is listening
  - Service is responsive
  - Network stack works

**Why 30s interval?**
- VS Code Server startup can be slow (5-15s)
- 30s interval provides quick feedback without excessive checking

**Why 3 retries before failure?**
- Allows transient blips (e.g., CPU spike causing slow response)
- 3 retries × 10s timeout = 30s total grace period

## Shared Bridge Network

### Why Shared vs. Isolated Per Session?

**Option A: Shared Bridge Network** (Chosen)
```yaml
networks:
  vscode-network:
    driver: bridge
```

**Pros:**
- Sessions can communicate (useful for coordination)
- Simpler DNS (all containers see each other)
- Easier debugging (can ping between sessions)

**Cons:**
- Slight security increase (network isolation per session would be better)

**Option B: Isolated Per Session**
```yaml
networks:
  vscode-network-1: ...
  vscode-network-2: ...
```

**Pros:**
- Better security (sessions can't reach each other)

**Cons:**
- Complex orchestration (need per-session bridge)
- Harder debugging
- Prevents session coordination

**Decision**: Shared bridge. Security isn't the main threat model (container IS the sandbox); coordination potential outweighs isolated networks.

## Container Socket Mount Strategy (Podman or Docker)

### Why Make It Optional?

```yaml
volumes:
  # Auto-detected socket path (podman rootless, rootful, or docker)
  - ${CONTAINER_SOCKET:-/run/podman/podman.sock}:/run/podman/podman.sock:ro
```

**Socket Paths:**
- Podman rootless (recommended): `/run/user/$UID/podman/podman.sock` (e.g., `/run/user/1000/podman/podman.sock`)
- Podman rootful: `/run/podman/podman.sock`
- Docker: `/var/run/docker.sock`

**If mounted:**
- Agents can spawn sibling containers (useful for E2E tests, nested builds)
- Read-only prevents socket manipulation
- Auto-detected by launcher.sh, overridable via `.env`

**If not mounted:**
- Agents can't spawn containers (acceptable)
- Better security (no privileged access)

**Decision**: Mount but read-only. Allows flexibility; read-only limits damage if exploited. Socket path auto-detected based on available runtime.

## Git Configuration in Container

```dockerfile
RUN git config --global --add safe.directory '*' && \
    git config --global user.email "agent@localhost" && \
    git config --global user.name "Container Agent"
```

**Why global config?**
- Agents need git to work (worktree creation, merges, commits)
- Global config prevents "not configured" errors
- `safe.directory '*'` allows worktrees with different owners

**Why generic email/name?**
- Agents are not individual developers
- Email/name are metadata; actual commits attributed in merge log
- Generic keeps things simple

## Startup Script Complexity

### Initialization Steps

1. Verify volumes mounted
2. Check docker socket (optional)
3. Setup npm sandbox (if package.json exists)
4. Verify VS Code user data directory
5. Health check
6. Start VS Code Server

**Why this order?**
- Fail fast if volumes missing (no point starting VS Code)
- Docker socket check is optional (graceful degradation)
- npm setup before VS Code (builds might start immediately)
- Health check last (can be slow, don't block startup)

## Why This Works for Multiple Sessions

### Key Insight: Volumes

Each session gets **independent named volumes**:
```
Session 1: vscode-session-1-data, vscode-session-1-config, vscode-session-1-cache
Session 2: vscode-session-2-data, vscode-session-2-config, vscode-session-2-cache
Session 3: vscode-session-3-data, vscode-session-3-config, vscode-session-3-cache
```

**Result**: Each session has completely independent VS Code state (settings, extensions, caches).

**Host mounts**:
```
Session 1: /path/to/workspace-1 → /workspace
Session 2: /path/to/workspace-2 → /workspace
Session 3: /path/to/workspace-3 → /workspace
```

**Result**: Each session has independent workspace and worktrees (no cross-session contamination).

**Ports**:
```
Session 1: 8443
Session 2: 8444
Session 3: 8445
```

**Result**: Each session is independently accessible.

## Trade-offs Summary

| Decision | Pro | Con |
|----------|-----|-----|
| Single Dockerfile | Simple | Larger image (~1.2 GB) |
| Named volumes | Persistent | Uses host disk |
| 4 CPU, 4 GB limit | Balanced | Might throttle heavy builds |
| Non-root vscode user | Secure | Some ops need sudo |
| Shared network | Coordinated | Slight security loss |
| Generic git config | Simple | Less personalized |
| Optional docker socket | Flexible | Requires read-only mount |

All trade-offs favor **simplicity and isolation** over optimization and fine-grained security.

## Next Steps

1. Validate image builds successfully
2. Test multi-session creation (2-3 parallel sessions)
3. Verify VS Code persistence (restart container, settings stick)
4. Test agent execution (run phase runners inside container)
5. Validate worktree operations (git operations work correctly)
6. Load test (3 sessions under concurrent load)

See [GUIDE.md](GUIDE.md) for testing procedures.

---

## SSL Layer Design Decisions

### Why nginx for TLS, Not VS Code's Built-in TLS

VS Code Server's `--cert` flag has known issues with self-signed certificates and connection token auth interactions. nginx as a dedicated TLS terminator is simpler, well-documented, and separates concerns cleanly.

**Decision**: nginx reverse proxy on `--network=host`. VS Code Server binds loopback-only.

### Why `--network=host` Instead of Port Mapping

Podman's default networking uses pasta userspace networking. Pasta breaks WebSocket connections — the browser successfully opens the WebSocket but it immediately closes (Error 1006). `--network=host` bypasses pasta entirely, binding nginx directly to the host network stack.

Docker-style `-p 8540:8540` port mapping works fine with Docker but was not the target runtime.

**Decision**: `--network=host` for all SSL containers.

### Why `$http_host` Not `$host` in nginx

nginx's `$host` variable normalises the Host header and strips the port number. VS Code Server constructs WebSocket URLs using the Host header, so stripping `:8540` makes it attempt `wss://hostname/` → port 443 → immediate failure.

`$http_host` passes the raw header value including the port.

**Decision**: `proxy_set_header Host $http_host;` — verified fix for WebSocket Error 1006.

### Why a Shared Connection Token Volume

Options considered:
1. Regenerate token on every container start — URL changes after every `ssl-remove`, breaking bookmarks
2. Per-session token volumes — different token per session, need separate bookmarks
3. Shared token volume — same token for all sessions, only port differs in URL

Option 3 is the most user-friendly. A single bookmark template works for all sessions. Token persists across container lifecycle events.

**Decision**: `vscode-ssl-token-shared` named volume mounted in all SSL sessions. Startup script checks for existing token before generating a new one.

### Why Extensions in a Named Volume (Not the Image)

Baking extensions into the image:
- Requires rebuild to add/remove extensions
- Extensions have large binary blobs (bad for image layers)
- Different sessions might want different extensions

Named volume per session:
- Installed interactively via VS Code's marketplace
- Survives `ssl-remove`/`ssl-create` (only `ssl-purge` removes them)
- Each session can have an independent extension set

**Decision**: `vscode-ssl-extensions-N` named volume per session, mounted at `/home/vscode/.vscode-server/extensions`.

### Why Ownership Fix at Startup (Not at Build Time)

Named volumes are created by Podman at `podman run` time and initialised as `root:root`. The `chown` cannot be done at image build time because the volume doesn't exist yet.

The startup script runs as root before dropping to `vscode` user for VS Code Server, making it the correct place to fix ownership.

**Decision**: `chown vscode:vscode <volume-mountpoints>` at the top of `startup-ssl.sh`.

### Why Workspace Trust Is Disabled by Config File, Not ENV

VS Code Server reads workspace trust settings from two scopes: Machine settings and User settings. Machine-scope alone is not sufficient for the web client — it reads User settings before applying Machine-scope overrides.

Injecting via environment variable has no supported mechanism. Generating settings at container startup would overwrite any user customisations.

**Decision**: `config/vscode-settings.json` is `COPY`'d at build time to both `/home/vscode/.vscode-server/data/Machine/settings.json` and `/home/vscode/.vscode-server/data/User/settings.json`. Single source of truth, baked in.

### Two Images Instead of One

Keeping HTTP (`vscode-agent:latest`) as a stable base and SSL (`vscode-agent:ssl`) as a separate layer means:
- Base image is usable standalone for local/HTTP development
- SSL image rebuilds are fast (only the nginx layer changes)
- Clear separation of concerns

**Decision**: `Dockerfile` → `vscode-agent:latest`. `Dockerfile.ssl` (`FROM vscode-agent:latest`) → `vscode-agent:ssl`.
