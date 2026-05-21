# BUILD_SESSION.md — RETIRED

This document recorded a VS Code fork compilation attempt from May 2026 that was **abandoned**.

**Why abandoned**: The fork approach was dropped in favour of using Microsoft's official
`vscode-server-linux-x64-web` binary downloaded directly at image build time. This is simpler,
always up to date, and requires no source compilation.

The current architecture is documented in:

- [ARCHITECTURE.md](ARCHITECTURE.md) — full system design
- [GUIDE.md](GUIDE.md) — how to build and run
- [HTTPS_SETUP.md](HTTPS_SETUP.md) — certificate and HTTPS setup
