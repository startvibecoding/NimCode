#!/usr/bin/env bash
set -euo pipefail

## Package and publish NimCode to npm.
## Usage:
##   ./scripts/npm-publish.sh              # build npm package (no publish)
##   ./scripts/npm-publish.sh --publish    # build and publish
##   ./scripts/npm-publish.sh --dry-run    # dry-run publish

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
NPM_DIR="$PROJECT_DIR/npm"
DIST_DIR="$PROJECT_DIR/dist"
NIMBLE_FILE="$PROJECT_DIR/nimcode.nimble"

VERSION="$(grep -E '^version\s*=' "$NIMBLE_FILE" | sed 's/.*=\s*"\([^"]*\)".*/\1/')"

echo "========================================"
echo "NimCode npm package"
echo "Version: $VERSION"
echo "========================================"

PUBLISH=false
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --publish) PUBLISH=true ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help)
      echo "Usage: $0 [--publish|--dry-run]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

if ! command -v npm &>/dev/null; then
  echo "ERROR: npm not found. Install Node.js first."
  exit 1
fi

if ! command -v node &>/dev/null; then
  echo "ERROR: node not found. Install Node.js first."
  exit 1
fi

# Build multi-platform binaries first
if [[ -f "$SCRIPT_DIR/build-cross-platform.sh" ]]; then
  echo "Building cross-platform binaries..."
  "$SCRIPT_DIR/build-cross-platform.sh"
else
  echo "ERROR: build-cross-platform.sh not found at $SCRIPT_DIR"
  exit 1
fi

# Prepare npm package directory
rm -rf "$NPM_DIR"
mkdir -p "$NPM_DIR/bin"

# Copy binaries
for binary in "$DIST_DIR"/nimcode-*; do
  if [[ -f "$binary" ]]; then
    cp "$binary" "$NPM_DIR/bin/"
    echo "Included binary: $(basename "$binary")"
  fi
done

if [[ ! -f "$NPM_DIR/bin/nimcode-linux-amd64" ]]; then
  echo "WARNING: no Linux amd64 binary found. Building fallback native binary..."
  nim c -d:release -d:ssl --opt:size -o:"$NPM_DIR/bin/nimcode" "$PROJECT_DIR/src/nimcode.nim"
fi

# Generate package.json from template
sed "s/{{VERSION}}/$VERSION/g" "$PROJECT_DIR/npm/package.json.template" > "$NPM_DIR/package.json"

# Copy install script and docs
cp "$PROJECT_DIR/npm/install.js" "$NPM_DIR/install.js"
chmod +x "$NPM_DIR/install.js"
if [[ -f "$PROJECT_DIR/README.md" ]]; then
  cp "$PROJECT_DIR/README.md" "$NPM_DIR/README.md"
fi
if [[ -f "$PROJECT_DIR/LICENSE" ]]; then
  cp "$PROJECT_DIR/LICENSE" "$NPM_DIR/LICENSE"
fi

# Verify package.json is valid JSON
echo ""
echo "Generated package.json:"
node -e "const p=require('$NPM_DIR/package.json'); console.log(JSON.stringify(p, null, 2))"

# Optional: pack tarball locally
NPM_TARBALL="$DIST_DIR/nimcode-${VERSION}.tgz"
cd "$NPM_DIR"
npm pack --pack-destination "$DIST_DIR" > /dev/null
echo ""
echo "Packed tarball: $NPM_TARBALL"

# Publish
if $DRY_RUN; then
  echo ""
  echo "Running npm publish --dry-run..."
  npm publish --dry-run
elif $PUBLISH; then
  echo ""
  echo "Publishing to npm..."
  if npm whoami &>/dev/null; then
    npm publish --access public
    echo "Published @nimcode/cli@$VERSION"
  else
    echo "ERROR: Not logged in to npm. Run 'npm login' first."
    exit 1
  fi
else
  echo ""
  echo "Package ready at $NPM_DIR"
  echo "To publish, run: $0 --publish"
  echo "To dry-run, run: $0 --dry-run"
fi

echo "========================================"
echo "Done."
echo "========================================"
