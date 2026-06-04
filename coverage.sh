#!/bin/bash
# Simple test coverage analysis for NimCode
# Analyzes which public procs are covered by tests

set -e

echo "=== NimCode Test Coverage Analysis ==="
echo ""

# Source modules to analyze
MODULES=(
  "src/nimcode/tui/tui.nim"
  "src/nimcode/tui/input.nim"
  "src/nimcode/tui/statusbar.nim"
  "src/nimcode/cli/stream.nim"
)

# Test files
TESTS=(
  "tests/test_tui.nim"
  "tests/test_statusbar.nim"
  "tests/test_stream.nim"
  "tests/test_input.nim"
)

total_procs=0
tested_procs=0

for module in "${MODULES[@]}"; do
  if [ ! -f "$module" ]; then
    continue
  fi
  
  module_name=$(basename "$module" .nim)
  echo "--- $module_name ---"
  
  # Extract public proc names (starting with lowercase after proc)
  procs=$(grep -E "^proc \w+\*" "$module" 2>/dev/null | sed 's/proc \([a-zA-Z0-9_]*\).*/\1/' || true)
  
  if [ -z "$procs" ]; then
    echo "  No public procs found"
    echo ""
    continue
  fi
  
  module_total=0
  module_tested=0
  
  while IFS= read -r proc_name; do
    if [ -z "$proc_name" ]; then
      continue
    fi
    
    module_total=$((module_total + 1))
    total_procs=$((total_procs + 1))
    
    # Check if proc is referenced in any test file
    found=false
    for test_file in "${TESTS[@]}"; do
      if [ -f "$test_file" ] && grep -q "$proc_name" "$test_file" 2>/dev/null; then
        found=true
        break
      fi
    done
    
    if [ "$found" = true ]; then
      echo "  ✓ $proc_name"
      module_tested=$((module_tested + 1))
      tested_procs=$((tested_procs + 1))
    else
      echo "  ✗ $proc_name"
    fi
  done <<< "$procs"
  
  if [ $module_total -gt 0 ]; then
    coverage=$((module_tested * 100 / module_total))
    echo "  Coverage: $module_tested/$module_total ($coverage%)"
  fi
  echo ""
done

echo "=== Summary ==="
if [ $total_procs -gt 0 ]; then
  overall_coverage=$((tested_procs * 100 / total_procs))
  echo "Total public procs: $total_procs"
  echo "Tested procs: $tested_procs"
  echo "Overall coverage: $overall_coverage%"
else
  echo "No public procs found to analyze"
fi
