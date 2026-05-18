#!/bin/bash
# Bootstrap a local Certificate Authority for VS Code container SSL sessions.
# Run this ONCE before using ssl-create for the first time.
#
# Generates:
#   ca-cert.pem  — CA public certificate (safe to distribute; import into browser)
#   ca-key.pem   — CA private key (keep secret; gitignored)
#
# Usage: bash ca/create-ca.sh [ca-dir]

set -euo pipefail

CA_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CERT="$CA_DIR/ca-cert.pem"
KEY="$CA_DIR/ca-key.pem"

if [[ -f "$CERT" && -f "$KEY" ]]; then
    echo "✓ CA already exists in $CA_DIR (delete ca-cert.pem + ca-key.pem to regenerate)"
    exit 0
fi

mkdir -p "$CA_DIR"

echo "Generating CA private key..."
openssl genrsa -out "$KEY" 4096 2>/dev/null

echo "Generating CA certificate (valid 10 years)..."
openssl req -x509 -new -nodes \
    -key "$KEY" \
    -sha256 -days 3650 \
    -out "$CERT" \
    -subj "/CN=VSCode-Container-CA/O=VSCode-Container-Lab/C=US" \
    2>/dev/null

chmod 600 "$KEY"
chmod 644 "$CERT"

echo ""
echo "✓ CA created in $CA_DIR"
echo ""
echo "  ca-cert.pem  — import this into your browser/OS trust store"
echo "  ca-key.pem   — keep this private (gitignored)"
echo ""
echo "Next: generate a server cert with:"
echo "  bash $CA_DIR/gen-cert.sh $CA_DIR vscode-server"
echo ""
echo "Browser trust (one-time):"
echo "  Chrome/Firefox: Settings → Certificates → Import ca-cert.pem as trusted CA"
echo "  Linux system:   sudo cp $CERT /usr/local/share/ca-certificates/vscode-ca.crt && sudo update-ca-certificates"
