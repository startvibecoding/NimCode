#!/usr/bin/env bash
set -euo pipefail

## Build a Debian package (.deb) for NimCode.
## Usage:
##   ./scripts/build-deb.sh              # build for host architecture
##   ./scripts/build-deb.sh amd64        # build for specified architecture

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_DIR/dist"
SRC="$PROJECT_DIR/src/nimcode.nim"
NIMBLE_FILE="$PROJECT_DIR/nimcode.nimble"

VERSION="$(grep -E '^version\s*=' "$NIMBLE_FILE" | sed 's/.*=\s*"\([^"]*\)".*/\1/')"

echo "========================================"
echo "NimCode Debian package build"
echo "Version: $VERSION"
echo "========================================"

# Validate tooling
if ! command -v dpkg-deb &>/dev/null; then
  echo "ERROR: dpkg-deb not found. Install with: sudo apt install dpkg-dev"
  exit 1
fi
if ! command -v nim &>/dev/null; then
  echo "ERROR: nim not found."
  exit 1
fi

# Architecture
ARCH="${1:-}"
if [[ -z "$ARCH" ]]; then
  case "$(uname -m)" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    armv7l|armv7) ARCH="armhf" ;;
    loongarch64) ARCH="loong64" ;;
    *) ARCH="amd64" ;;
  esac
fi

PKG_NAME="nimcode"
DEB_VERSION="${VERSION}"
PKG_DIR="$DIST_DIR/${PKG_NAME}_${DEB_VERSION}_${ARCH}"
DEB_FILE="${PKG_NAME}_${DEB_VERSION}_${ARCH}.deb"

echo "Package:  $PKG_NAME"
echo "Version:  $DEB_VERSION"
echo "Arch:     $ARCH"
echo "Output:   $DIST_DIR/$DEB_FILE"
echo ""

# Clean and create package staging area
rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/DEBIAN"
mkdir -p "$PKG_DIR/usr/bin"
mkdir -p "$PKG_DIR/usr/share/doc/$PKG_NAME"
mkdir -p "$PKG_DIR/usr/share/man/man1"

# Build the binary
BINARY_NAME="nimcode"
nim c -d:release -d:ssl --opt:size -o:"$PKG_DIR/usr/bin/$BINARY_NAME" "$SRC"
chmod 755 "$PKG_DIR/usr/bin/$BINARY_NAME"

# Write control file
cat > "$PKG_DIR/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: $DEB_VERSION
Section: utils
Priority: optional
Architecture: $ARCH
Depends: libc6
Maintainer: NimCode <support@nimcode.dev>
Description: AI coding assistant in the terminal
 NimCode is a terminal-based AI coding assistant supporting
 multiple providers, tools, sessions, and interactive TUI.
EOF

# Write conffiles (none for now)
touch "$PKG_DIR/DEBIAN/conffiles"

# Copy documentation
if [[ -f "$PROJECT_DIR/README.md" ]]; then
  cp "$PROJECT_DIR/README.md" "$PKG_DIR/usr/share/doc/$PKG_NAME/"
fi
if [[ -f "$PROJECT_DIR/LICENSE" ]]; then
  cp "$PROJECT_DIR/LICENSE" "$PKG_DIR/usr/share/doc/$PKG_NAME/copyright"
fi

# Generate minimal man page if not present
if [[ ! -f "$PROJECT_DIR/deb/nimcode.1" ]]; then
  cat > "$PKG_DIR/usr/share/man/man1/nimcode.1" <<EOF
.TH NIMCODE 1 "$DEB_VERSION" "NimCode"
.SH NAME
nimcode \- AI coding assistant in the terminal
.SH SYNOPSIS
.B nimcode
[\fIOPTIONS\fR] [\fIMESSAGE\fR...]
.SH DESCRIPTION
NimCode is a terminal-based AI coding assistant.
Run it interactively or pass \fB-P\fR for a single-shot response.
.SH OPTIONS
.TP
.BR \-p ", " \-\-provider " " \fINAME\fR
Provider name from settings.
.TP
.BR \-m ", " \-\-model " " \fIID\fR
Model ID.
.TP
.BR \-M ", " \-\-mode " " \fIMODE\fR
Mode: plan, agent, yolo.
.TP
.BR \-P ", " \-\-print
Print response and exit (non-interactive).
.TP
.BR \-h ", " \-\-help
Show help and exit.
.SH SEE ALSO
Project page: https://github.com/nimcode/nimcode
EOF
  gzip -9 -n "$PKG_DIR/usr/share/man/man1/nimcode.1"
else
  cp "$PROJECT_DIR/deb/nimcode.1" "$PKG_DIR/usr/share/man/man1/"
  gzip -9 -n "$PKG_DIR/usr/share/man/man1/nimcode.1"
fi

# Strip binary for smaller package (best effort)
if command -v strip &>/dev/null; then
  strip --strip-unneeded "$PKG_DIR/usr/bin/$BINARY_NAME" || true
fi

# Build the .deb package
mkdir -p "$DIST_DIR"
dpkg-deb --build --root-owner-group "$PKG_DIR" "$DIST_DIR/$DEB_FILE"

# Validate
if command -v lintian &>/dev/null; then
  echo ""
  echo "Running lintian..."
  lintian "$DIST_DIR/$DEB_FILE" || true
fi

# Cleanup staging area
rm -rf "$PKG_DIR"

echo ""
echo "========================================"
echo "Built: $DIST_DIR/$DEB_FILE"
dpkg-deb --info "$DIST_DIR/$DEB_FILE" | grep -E 'Package|Version|Architecture|Depends'
echo "========================================"
