#!/bin/bash
# Run all unit tests for NimCode

set -e

echo "Running NimCode unit tests..."
echo ""

NIM=${NIM:-nim}
FLAGS="-d:ssl"

echo "=== TUI Tests ==="
$NIM c -r $FLAGS tests/test_tui.nim
echo ""

echo "=== Status Bar Tests ==="
$NIM c -r $FLAGS tests/test_statusbar.nim
echo ""

echo "=== Stream Tests ==="
$NIM c -r $FLAGS tests/test_stream.nim
echo ""

echo "=== Input Tests ==="
$NIM c -r $FLAGS tests/test_input.nim
echo ""

echo "All tests passed!"
