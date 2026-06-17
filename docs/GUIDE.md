# Step-by-Step Guide — VS Code Server in a Container

This guide explains everything from scratch. No experience needed.

---

## What Is This?

Imagine VS Code — the code editor — running inside a little isolated box (called a **container**) on your computer. You open it in a **web browser** instead of installing it directly. This means:

- Your code projects are safe inside the container
- You can run up to **3 separate VS Code sessions** at once, each with its own project
- It uses **HTTPS** (the padlock in your browser bar) so it's secure even on your local network
- Extensions and settings survive when you stop and restart the container

---

## Before You Start

You need these installed on your computer:

- **Podman** (like Docker, but runs without needing root/admin) — `podman --version` to check
- **openssl** — usually already installed on Linux — `openssl version` to check
- This project folder cloned to your computer

---

## One-Time Setup (Do This Once Per Computer)

These steps only need to be done once. Skip them on future uses.

### Step 1 — Create a Certificate Authority (CA)

A CA is like your own personal stamp of approval for security certificates. Your browser will trust certificates stamped by it.

```bash
bash ca/create-ca.sh
```

This creates two files:

- `ca/ca-cert.pem` — the public stamp (you'll import this into your browser)
- `ca/ca-key.pem` — the private key (keep this secret, it's in .gitignore)

---

### Step 2 — Generate a Server Certificate

This certificate is what makes the padlock appear in your browser.

```bash
bash ca/gen-cert.sh ca/ vscode-server
```

This detects your computer's local IP address automatically and creates:

- `ca/server.crt` — the certificate
- `ca/server.key` — the certificate's private key

> **If your IP address changes** (e.g. you reconnect to WiFi), re-run this command.

---

### Step 3 — Tell Your Browser to Trust Your CA

Your browser doesn't know about your homemade CA yet, so it will show a scary warning. Fix this by importing `ca/ca-cert.pem`:

**Chrome or Edge:**

1. Open Settings
2. Search for "certificates"
3. Click "Manage certificates" → "Authorities" tab
4. Click "Import" and choose `ca/ca-cert.pem`
5. Tick "Trust this certificate for identifying websites"
6. Click OK

**Firefox:**

1. Open Settings
2. Search for "certificates"
3. Click "View Certificates" → "Authorities" tab
4. Click "Import" and choose `ca/ca-cert.pem`
5. Tick "Trust this CA to identify websites"
6. Click OK

> You only need to do this once per browser.

---

### Step 4 — Build the Container Image

This downloads VS Code Server and packages everything up. It takes a few minutes the first time.

```bash
./scripts/launcher.sh build
```

You'll see lots of output as it downloads and installs things. It's done when you see:

```
✓ Image built: vscode-agent:default
```

> **You only need to rebuild** when the Dockerfile changes (e.g. after a project update).

---

## Every Day — Starting a Session

### Step 5 — Create a VS Code Session

Pick a session number (1, 2, or 3) and give it the path to your project folder:

```bash
./scripts/launcher.sh create 1 /path/to/your/project
```

For example:

```bash
./scripts/launcher.sh create 1 /raid5/source/myproject
```

When it's ready, it prints a URL like:

```
URL: https://192.168.1.50:8550/?tkn=abc123def456...&folder=/workspace
```

**Copy that URL and open it in your browser.** Done! VS Code opens in your browser.

---

## Managing Sessions

### See All Running Sessions

```bash
./scripts/launcher.sh list
```

This shows every active session with its URL and connection token.

---

### Get the URL Again (If You Forgot It)

```bash
./scripts/launcher.sh token 1
```

Replace `1` with your session number.

---

### Stop a Session (Keep Your Data)

```bash
./scripts/launcher.sh stop 1
```

The container stops but all your extensions and settings are saved. Start it again with `create`.

---

### Remove a Session (Container Gone, Data Stays)

```bash
./scripts/launcher.sh remove 1
```

The container is deleted but your extensions and VS Code settings are saved in named volumes. They'll be there when you create a new session.

---

### Purge a Session (Clean Slate)

```bash
./scripts/launcher.sh purge 1
```

Removes the container **and** all its volumes — extensions, settings, server data. Use this when you want to start completely fresh. You'll need to type `yes` to confirm.

---

## Session Ports

Each session uses a different port so they don't clash:

| Session | URL Port | Example URL |
|---------|---------|-------------|
| 1 | 8550 | `https://192.168.x.x:8550/?tkn=...` |
| 2 | 8551 | `https://192.168.x.x:8551/?tkn=...` |
| 3 | 8552 | `https://192.168.x.x:8552/?tkn=...` |

---

## What Gets Saved?

Here's what persists across container restarts (you won't lose it):

| What | Saved? |
|------|--------|
| Your code/project files | Yes — they're on your host machine, not in the container |
| VS Code extensions you install | Yes — saved in a named volume |
| VS Code settings and state | Yes — saved in a named volume |
| Connection token (the `?tkn=` in the URL) | Yes — shared token, same URL every time |

---

## All Commands at a Glance

```bash
# One-time setup
bash ca/create-ca.sh                              # Create your CA
bash ca/gen-cert.sh ca/ vscode-server             # Generate server cert
./scripts/launcher.sh build                       # Build the container image

# Session management
./scripts/launcher.sh create 1 /my/project        # Start session 1
./scripts/launcher.sh create 2 /my/project        # Start session 2
./scripts/launcher.sh list                        # Show all active sessions
./scripts/launcher.sh token 1                     # Get URL for session 1
./scripts/launcher.sh stop 1                      # Stop session 1 (data kept)
./scripts/launcher.sh remove 1                    # Remove container (data kept)
./scripts/launcher.sh purge 1                     # Remove container + all volumes
```

---

## Something Went Wrong?

Check container logs first:
```bash
podman logs vscode-ssl-v2-1
```

Common issues: port already in use (`ss -tlnp | grep 8550`), certs missing (`ca/server.crt`), image not built (`./scripts/launcher.sh build`).

---

## Clearing Browser Cache (IndexedDB)

VS Code stores provider configs (like OpenRouter API keys) in your browser's IndexedDB. If you see stale entries or "previous config" warnings when adding a model provider, clear the IndexedDB:

Open this URL in your browser (replace `<host>` and `<token>` with your actual values):

```
https://<host>:<port>/clear-cache
```

For example:
```
https://192.168.1.50:8550/clear-cache
```

This wipes all IndexedDB databases for that origin, then automatically redirects to VS Code with a fresh state. You'll need to re-add any custom model providers after clearing.

---

## Crash Recovery

If VS Code crashes (e.g. when adding workspace folders), the container automatically restarts VS Code — it doesn't kill the container. Check the logs to see restart events:

```bash
podman logs vscode-ssl-v2-1 -f
# Look for: "[startup-v2] VS Code crashed — restarting (attempt N)..."
```

The container only shuts down if nginx or mint-proxy dies (which would be unrecoverable).

---

## How It Works (Simple Version)

```
Your browser
    ↓  HTTPS (encrypted, padlock)
nginx inside the container  (handles the encryption)
    ↓  unencrypted, but only inside the container
mint-proxy  (handles secret storage for extensions)
    ↓
VS Code Server  (the actual editor)
    ↓
Your project files  (mounted from your computer)
```

The token in the URL (`?tkn=abc123...`) is like a password — VS Code checks it when you first connect, then remembers you via a cookie.

---

## Further Reading

- [HTTPS_SETUP.md](HTTPS_SETUP.md) — deeper dive into certificates and HTTPS
- [ARCHITECTURE.md](ARCHITECTURE.md) — full technical design
- [DESIGN_DECISIONS.md](DESIGN_DECISIONS.md) — why things were built this way
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — fixing common problems
