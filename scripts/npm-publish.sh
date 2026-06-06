#!/usr/bin/env bash
set -euo pipefail

## Package and publish NimCode to npm.
## Usage:
##   ./scripts/npm-publish.sh              # build npm package (no publish)
##   ./scripts/npm-publish.sh --publish    # build and publish
##   ./scripts/npm-publish.sh --dry-run    # dry-run publish

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
NPM_TEMPLATES_DIR="$PROJECT_DIR/npm"
NPM_STAGING_DIR="$PROJECT_DIR/npm-staging"
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

# Build multi-platform binaries first (best effort)
if [[ -f "$SCRIPT_DIR/build-cross-platform.sh" ]]; then
  echo "Building cross-platform binaries..."
  set +e
  "$SCRIPT_DIR/build-cross-platform.sh"
  build_exit=$?
  set -e
  if [[ $build_exit -ne 0 ]]; then
    echo "WARNING: cross-platform build had failures; continuing with available binaries."
  fi
else
  echo "ERROR: build-cross-platform.sh not found at $SCRIPT_DIR"
  exit 1
fi

# Verify we have at least one binary to ship
if [[ ! -d "$DIST_DIR" ]] || [[ -z "$(ls -A "$DIST_DIR"/nimcode-* 2>/dev/null)" ]]; then
  echo "ERROR: no binaries available to package."
  exit 1
fi

# Prepare npm package directory
rm -rf "$NPM_STAGING_DIR"
mkdir -p "$NPM_STAGING_DIR/bin"

# Copy binaries
for binary in "$DIST_DIR"/nimcode-*; do
  if [[ -f "$binary" ]]; then
    cp "$binary" "$NPM_STAGING_DIR/bin/"
    echo "Included binary: $(basename "$binary")"
  fi
done

if [[ ! -f "$NPM_STAGING_DIR/bin/nimcode-linux-amd64" ]]; then
  echo "WARNING: no Linux amd64 binary found. Building fallback native binary..."
  nim c -d:release -d:ssl --opt:size -o:"$NPM_STAGING_DIR/bin/nimcode" "$PROJECT_DIR/src/nimcode.nim"
fi

# Generate package.json from template
sed "s/{{VERSION}}/$VERSION/g" "$PROJECT_DIR/npm/package.json.template" > "$NPM_STAGING_DIR/package.json"

# Copy install script and docs
cp "$PROJECT_DIR/npm/install.js" "$NPM_STAGING_DIR/install.js"
chmod +x "$NPM_STAGING_DIR/install.js"
if [[ -f "$PROJECT_DIR/README.md" ]]; then
  cp "$PROJECT_DIR/README.md" "$NPM_STAGING_DIR/README.md"
fi
if [[ -f "$PROJECT_DIR/LICENSE" ]]; then
  cp "$PROJECT_DIR/LICENSE" "$NPM_STAGING_DIR/LICENSE"
fi

# Verify package.json is valid JSON
echo ""
echo "Generated package.json:"
node -e "const p=require('$NPM_STAGING_DIR/package.json'); console.log(JSON.stringify(p, null, 2))"

# Optional: pack tarball locally
NPM_TARBALL="$DIST_DIR/nimcode-${VERSION}.tgz"
cd "$NPM_STAGING_DIR"
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
  echo "Package ready at $NPM_STAGING_DIR"
  echo "To publish, run: $0 --publish"
  echo "To dry-run, run: $0 --dry-run"
fi

echo "========================================"
echo "Done."
echo "========================================"
