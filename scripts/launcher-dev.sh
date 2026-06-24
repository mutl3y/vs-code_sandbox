#!/bin/bash
# ============================================================================
# Dev launcher — thin wrapper around launcher.sh dev
# ============================================================================
# This file exists for backward compatibility. All logic is in launcher.sh.
# Usage: ./scripts/launcher-dev.sh <command> [args...]
# Equivalent to: ./scripts/launcher.sh dev <command> [args...]
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/launcher.sh" dev "$@"
