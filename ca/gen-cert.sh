#!/bin/bash
# Generate and sign SSL certificates using local CA
# Usage: ./gen-cert.sh <output-dir> <common-name>

set -e

OUTPUT_DIR="${1:-.}"
COMMON_NAME="${2:-code-server}"
CA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ensure CA files exist
if [ ! -f "$CA_DIR/ca-cert.pem" ] || [ ! -f "$CA_DIR/ca-key.pem" ]; then
    echo "Error: CA files not found in $CA_DIR"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Generate server key
openssl genrsa -out "$OUTPUT_DIR/server.key" 2048 2>/dev/null

# Create certificate signing request
openssl req -new -key "$OUTPUT_DIR/server.key" \
    -out "$OUTPUT_DIR/server.csr" \
    -subj "/CN=$COMMON_NAME/O=VSCode-Container-Lab/C=US" \
    2>/dev/null

# Create temporary extension file
# Auto-detect host LAN IP for SAN (falls back to localhost-only if not found)
HOST_IP=$(hostname -I | awk '{print $1}')
EXTFILE=$(mktemp)
if [ -n "$HOST_IP" ] && [ "$HOST_IP" != "127.0.0.1" ]; then
    cat > "$EXTFILE" << EXTCONF
subjectAltName=DNS:localhost,IP:127.0.0.1,IP:${HOST_IP}
EXTCONF
else
    cat > "$EXTFILE" << EXTCONF
subjectAltName=DNS:localhost,IP:127.0.0.1
EXTCONF
fi

# Sign with CA (1-year validity)
openssl x509 -req -days 365 \
    -in "$OUTPUT_DIR/server.csr" \
    -CA "$CA_DIR/ca-cert.pem" \
    -CAkey "$CA_DIR/ca-key.pem" \
    -CAcreateserial \
    -out "$OUTPUT_DIR/server.crt" \
    -extfile "$EXTFILE" \
    2>/dev/null

# Cleanup
rm -f "$OUTPUT_DIR/server.csr" "$CA_DIR/ca-cert.srl" "$EXTFILE"

# Set permissions
chmod 600 "$OUTPUT_DIR/server.key"
chmod 644 "$OUTPUT_DIR/server.crt"

echo "✓ Certificate generated: $OUTPUT_DIR/server.crt"
