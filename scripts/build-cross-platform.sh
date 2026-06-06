#!/usr/bin/env bash
set -euo pipefail

## Cross-platform build script for NimCode
## Builds release binaries for multiple OS/architecture combinations.
## Usage:
##   ./scripts/build-cross-platform.sh              # build all targets
##   ./scripts/build-cross-platform.sh linux amd64  # build single target
##   ./scripts/build-cross-platform.sh --native     # build only host target

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_DIR/dist"
SRC="$PROJECT_DIR/src/nimcode.nim"
NIMBLE_FILE="$PROJECT_DIR/nimcode.nimble"

VERSION="$(grep -E '^version\s*=' "$NIMBLE_FILE" | sed 's/.*=\s*"\([^"]*\)".*/\1/')"

echo "========================================"
echo "NimCode cross-platform build"
echo "Version: $VERSION"
echo "========================================"

# Detect host platform
HOST_OS=""
HOST_ARCH=""
case "$(uname -s)" in
  Linux*)  HOST_OS="linux" ;;
  Darwin*) HOST_OS="macos" ;;
  MINGW*|MSYS*|CYGWIN*) HOST_OS="windows" ;;
  *)       HOST_OS="linux" ;;
esac
case "$(uname -m)" in
  x86_64|amd64) HOST_ARCH="amd64" ;;
  aarch64|arm64) HOST_ARCH="arm64" ;;
  armv7l|armv7) HOST_ARCH="arm" ;;
  *)            HOST_ARCH="amd64" ;;
esac

NATIVE_ONLY=false
TARGETS=()

if [[ "${1:-}" == "--native" ]]; then
  NATIVE_ONLY=true
  shift || true
fi

if [[ $# -ge 2 ]]; then
  TARGETS=("$1:$2")
elif $NATIVE_ONLY; then
  TARGETS=("$HOST_OS:$HOST_ARCH")
else
  TARGETS=(
    "linux:amd64"
    "linux:arm64"
    "linux:arm"
    "macos:amd64"
    "macos:arm64"
    "windows:amd64"
  )
fi

mkdir -p "$DIST_DIR"

# Map OS/arch names to Nim compiler flags
nim_os() {
  case "$1" in
    linux) echo "linux" ;;
    macos) echo "macosx" ;;
    windows) echo "windows" ;;
    *) echo "$1" ;;
  esac
}

nim_cpu() {
  case "$1" in
    amd64) echo "amd64" ;;
    arm64) echo "arm64" ;;
    arm) echo "arm" ;;
    *) echo "$1" ;;
  esac
}

binary_ext() {
  if [[ "$1" == "windows" ]]; then
    echo ".exe"
  else
    echo ""
  fi
}

# Try to locate a cross-compiler. This is a best-effort helper.
locate_cross_cc() {
  local target_os="$1"
  local target_arch="$2"
  local compiler=""

  # Prefer zig cc if available (it covers most cross targets)
  if command -v zig &>/dev/null; then
    echo "zig cc"
    return
  fi

  # Check for GNU cross-compilers on PATH
  case "${target_os}-${target_arch}" in
    linux-amd64)
      for c in x86_64-linux-gnu-gcc x86_64-pc-linux-gnu-gcc; do
        if command -v "$c" &>/dev/null; then compiler="$c"; break; fi
      done
      ;;
    linux-arm64)
      for c in aarch64-linux-gnu-gcc aarch64-unknown-linux-gnu-gcc; do
        if command -v "$c" &>/dev/null; then compiler="$c"; break; fi
      done
      ;;
    linux-arm)
      for c in arm-linux-gnueabihf-gcc armv7l-linux-gnueabihf-gcc; do
        if command -v "$c" &>/dev/null; then compiler="$c"; break; fi
      done
      ;;
    macos-*)
      # macOS cross-compilation typically requires osxcross or building on macOS
      compiler=""
      ;;
    windows-amd64)
      for c in x86_64-w64-mingw32-gcc mingw-w64-gcc; do
        if command -v "$c" &>/dev/null; then compiler="$c"; break; fi
      done
      ;;
  esac

  if [[ -n "$compiler" ]]; then
    echo "$compiler"
  else
    echo ""
  fi
}

build_target() {
  local target_os="$1"
  local target_arch="$2"
  local os_flag cpu_flag cc out_name ext

  os_flag="$(nim_os "$target_os")"
  cpu_flag="$(nim_cpu "$target_arch")"
  ext="$(binary_ext "$target_os")"
  out_name="nimcode-${target_os}-${target_arch}${ext}"

  echo ""
  echo "Building: $target_os / $target_arch -> $out_name"

  # Skip cross-compilation when host cannot satisfy it and it's not the native target
  if [[ "$target_os" == "macos" && "$HOST_OS" != "macos" ]]; then
    echo "  SKIP: macOS binaries must be built on macOS (or with osxcross)."
    return 0
  fi

  local cc_args=()
  if [[ "$target_os" == "$HOST_OS" && "$target_arch" == "$HOST_ARCH" ]]; then
    echo "  Native build"
  else
    cc="$(locate_cross_cc "$target_os" "$target_arch")"
    if [[ -z "$cc" ]]; then
      echo "  SKIP: no cross-compiler found for ${target_os}-${target_arch}"
      return 0
    fi
    echo "  Cross-compiler: $cc"
    if [[ "$cc" == "zig cc" ]]; then
      local zig_target="${cpu_flag}-${os_flag}-musl"
      [[ "$target_os" == "windows" ]] && zig_target="${cpu_flag}-${os_flag}-gnu"
      cc_args+=(
        "--cc:gcc"
        "--gcc.exe:zig"
        "--gcc.linkerexe:zig"
        "--passC:-target ${zig_target}"
        "--passL:-target ${zig_target}"
      )
    else
      cc_args+=(
        "--cc:gcc"
        "--gcc.exe:$cc"
        "--gcc.linkerexe:$cc"
      )
    fi
  fi

  nim c \
    -d:release \
    -d:ssl \
    --opt:size \
    --os:"$os_flag" \
    --cpu:"$cpu_flag" \
    "${cc_args[@]}" \
    -o:"$DIST_DIR/$out_name" \
    "$SRC"

  echo "  OK: $DIST_DIR/$out_name"
}

# Main build loop
failed=0
for target in "${TARGETS[@]}"; do
  tos="${target%%:*}"
  tarch="${target##*:}"
  if ! build_target "$tos" "$tarch"; then
    failed=$((failed + 1))
  fi
done

echo ""
echo "========================================"
if [[ $failed -gt 0 ]]; then
  echo "Build finished with $failed failure(s)."
  exit 1
fi

echo "Built artifacts in $DIST_DIR:"
ls -lh "$DIST_DIR"
echo "========================================"
