#!/usr/bin/env zsh
# test-netdoctor.zsh
# Quick sanity-check harness for netdoctor-repair-macos.zsh
# No sudo, no network dependency required.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/netdoctor-repair-macos.zsh"
PASS=0
FAIL=0

SCRIPT_VERSION="$(grep -E '^SCRIPT_VERSION=' "$TARGET" 2>/dev/null | head -n1 | sed -E 's/^SCRIPT_VERSION="([^"]+)"$/\1/' || true)"
[[ -n "$SCRIPT_VERSION" ]] || SCRIPT_VERSION="unknown"

pass() { print -r -- "  PASS  $*"; (( PASS++ )) || true; }
fail() { print -r -- "  FAIL  $*"; (( FAIL++ )) || true; }

print -r -- ""
print -r -- "NetDoctor v${SCRIPT_VERSION} — test harness"
print -r -- "Target: $TARGET"
print -r -- ""

# ── 1. File exists ──────────────────────────────────────────────────────
print -r -- "[1/5] File exists"
if [[ -f "$TARGET" ]]; then
  pass "Script file found"
else
  fail "Script file NOT found: $TARGET"
  print -r -- ""
  print -r -- "FAILED (1 check failed)"
  exit 1
fi

# ── 2. Syntax check ─────────────────────────────────────────────────────
print -r -- "[2/5] Syntax check (zsh -n)"
if zsh -n "$TARGET" 2>/dev/null; then
  pass "Syntax OK"
else
  fail "Syntax errors detected"
fi

# ── 3. Executable ───────────────────────────────────────────────────────
print -r -- "[3/5] Executable bit"
if [[ -x "$TARGET" ]]; then
  pass "Script is executable"
else
  fail "Script is NOT executable (run: chmod +x $TARGET)"
fi

# ── 4. --help output ────────────────────────────────────────────────────
print -r -- "[4/5] --help output"
if "$TARGET" --help 2>&1 | grep -q 'NetDoctor'; then
  pass "--help output contains expected content"
else
  fail "--help output missing or unexpected"
fi

# ── 5. Invalid option exits non-zero ────────────────────────────────────
print -r -- "[5/5] Invalid option handling"
if ! "$TARGET" --invalid-option-xyz 2>/dev/null; then
  pass "Invalid option correctly rejected (non-zero exit)"
else
  fail "Invalid option did NOT produce a non-zero exit"
fi

# ── Summary ─────────────────────────────────────────────────────────────
print -r -- ""
if (( FAIL == 0 )); then
  print -r -- "All ${PASS} checks passed."
  exit 0
else
  print -r -- "FAILED: ${FAIL} check(s) failed, ${PASS} passed."
  exit 1
fi




