# Troubleshooting

Common problems and how to fix them.

---

## Build Errors

### `STARTUP_HTTPS: unterminated heredoc`

The heredoc close tag in the Dockerfile doesn't match the open tag.

**Fix**: Make sure the closing tag at the bottom of the inline script matches the opening:
```dockerfile
COPY <<'STARTUP_HTTPS' /opt/init/startup.sh
...script...
STARTUP_HTTPS        ← must match exactly
```

---

### `Failed to decode the keys ["storage.options.volumePath"]`

The `volumePath` key was removed from containers-storage in newer Podman versions.

**Fix**:
```bash
sed -i '/volumePath/d' ~/.config/containers/storage.conf
```

This is safe — Podman already defaults volumes to `${graphRoot}/volumes`.

---

### `Error: creating container storage: creating an ID-mapped copy of layer`

Usually caused by the storage.conf warning above appearing during a build. Fix the storage.conf warning first, then retry the build.

---

### Image not found after build

Check the build succeeded and the tag exists:
```bash
podman images | grep vscode-agent
```

Expected output:
```
localhost/vscode-agent   default   abc123...   ...
localhost/vscode-agent   stable    abc123...   ...
localhost/vscode-agent   ssl-v2    abc123...   ...
localhost/vscode-agent   latest    abc123...   ...
```

If missing, re-run:
```bash
./scripts/launcher.sh build
```

---

## Certificate Errors

### Browser shows "Your connection is not private" / `NET::ERR_CERT_AUTHORITY_INVALID`

The CA certificate hasn't been imported into your browser yet.

**Fix**: Import `ca/ca-cert.pem` into your browser. See [HTTPS_SETUP.md](HTTPS_SETUP.md) for browser-specific steps.

---

### `Certs not found: ca/server.crt / ca/server.key`

The server certificate hasn't been generated yet.

**Fix**:
```bash
bash ca/gen-cert.sh ca/ vscode-server
```

---

### Certificate works on one machine but not another

The server cert embeds your host's LAN IP address in its SAN. If the IP changes, regenerate:
```bash
bash ca/gen-cert.sh ca/ vscode-server
```

---

## Session / Container Errors

### Container starts but URL shows "Unable to connect"

Wait 5–10 seconds for VS Code to finish booting, then refresh. Check logs:
```bash
podman logs vscode-ssl-v2-1
```

Look for `[startup-v2] HTTPS:` line — this confirms VS Code is ready.

---

### Token shows as `UNKNOWN` in the URL

VS Code hasn't finished writing the token file yet. Wait a few seconds then re-run:
```bash
./scripts/launcher.sh ssl-v2-token 1
```

---

### WebSocket Error 1006 / editor hangs on load

This is the `$host` vs `$http_host` nginx problem. The nginx config should already use `$http_host`.
Check the generated config inside the container:
```bash
podman exec vscode-ssl-v2-1 cat /etc/nginx/conf.d/vscode.conf | grep Host
```

Expected: `proxy_set_header   Host $http_host;`

---

### Container exits immediately

Check logs for the cause:
```bash
podman logs vscode-ssl-v2-1
```

Common causes:
- SSL certs not mounted (check `ca/server.crt` and `ca/server.key` exist)
- Port already in use — check with `ss -tlnp | grep 8550`
- VS Code binary not found in image (rebuild the image)

---

### Port already in use

```bash
ss -tlnp | grep 8550
```

If something is already using port 8550, either stop that process or use a different session number:
```bash
./scripts/launcher.sh ssl-v2-create 2 /your/path   # uses port 8551 instead
```

---

## Secret Storage / Extension Auth Problems

### GitHub extension keeps asking to sign in after page refresh

This means mint-proxy isn't running or the secret cookies aren't being set.

Check mint-proxy is running inside the container:
```bash
podman exec vscode-ssl-v2-1 pgrep -a node
```

Expected: a `node /opt/mint-proxy.js` process.

---

### Extensions lose settings on container restart

Extensions store secrets via VS Code's secret API. The `vscode-ssl-v2-server-data-N` volume persists this across restarts. If you used `ssl-v2-remove`, the data volume is gone — that's intentional.

Use `ssl-v2-stop` (not `ssl-v2-remove`) to stop and restart while keeping all data.

---

## Podman-Specific

### `WARN[0000] pasta networking...` or WebSocket failures with pasta

Pasta networking (Podman's default) breaks WebSocket. The launcher already uses `--network=host` to avoid this.

If you see this with docker-compose / podman-compose sessions, make sure `network_mode: host` is set in `docker-compose.yml`.

---

### Podman version is old and doesn't support heredoc COPY

Heredoc `COPY` syntax requires BuildKit / Podman 4.0+. Check:
```bash
podman --version
```

Minimum: Podman 4.0. Recommended: Podman 5.x.

---

## Checking Logs

```bash
# Live logs from session 1
podman logs -f vscode-ssl-v2-1

# All running containers
podman ps

# All containers including stopped
podman ps -a

# Volume list
podman volume ls | grep vscode
```
