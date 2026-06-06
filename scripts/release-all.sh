#!/usr/bin/env bash
set -euo pipefail

## Master release script: build binaries, .deb, and npm package.
## Usage:
##   ./scripts/release-all.sh
##   ./scripts/release-all.sh --publish-npm

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
NIMBLE_FILE="$PROJECT_DIR/nimcode.nimble"
VERSION="$(grep -E '^version\s*=' "$NIMBLE_FILE" | sed 's/.*=\s*"\([^"]*\)".*/\1/')"

PUBLISH_NPM=false
if [[ "${1:-}" == "--publish-npm" ]]; then
  PUBLISH_NPM=true
fi

echo "========================================"
echo "NimCode release build: v$VERSION"
echo "========================================"

# 1. Cross-platform binaries
echo ""
echo "[1/4] Building cross-platform binaries..."
"$SCRIPT_DIR/build-cross-platform.sh"

# 2. Debian package for host arch
echo ""
echo "[2/4] Building Debian package..."
"$SCRIPT_DIR/build-deb.sh"

# 3. npm package
echo ""
echo "[3/4] Building npm package..."
if $PUBLISH_NPM; then
  "$SCRIPT_DIR/npm-publish.sh" --publish
else
  "$SCRIPT_DIR/npm-publish.sh"
fi

# 4. Summary
echo ""
echo "[4/4] Release artifacts:"
echo "========================================"
ls -lh "$PROJECT_DIR/dist/"
echo "========================================"

if ! $PUBLISH_NPM; then
  echo ""
  echo "To publish to npm, run:"
  echo "  ./scripts/release-all.sh --publish-npm"
fi
