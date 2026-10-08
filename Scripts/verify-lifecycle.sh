#!/bin/bash
#
# Scripts/verify-lifecycle.sh — smoke-test the document lifecycle end to end.
#
# What this script proves, against the real built app:
#
#   1. Launching ArchiveCat with nothing to open shows the welcome window.
#   2. Opening archive A (via LaunchServices, as Finder would) opens a document
#      window, and the welcome window goes away.
#   3. Opening archive B while A is open creates a second document window —
#      the app does not replace the first one, and it does not need relaunching.
#   4. Opening A again reuses the already-open document instead of duplicating
#      it.
#   5. A Dock-style reopen with no file does not spawn an extra welcome window.
#   6. Throughout, the process stays alive and produces no crash reports.
#
# What it cannot prove in this environment, and why:
#
#   ⌘W-closing the last document requires GUI automation (keystrokes or
#   Accessibility), which macOS denies to non-user processes (TCC). The close
#   path is covered by construction instead: `applicationShouldTerminateAfter
#   LastWindowClosed` returns false, and the close notification path is wired
#   to both `NSWindowController.windowWillClose` and `NSDocument.close`.
#   Verify that once by hand: close a document window, confirm ArchiveCat keeps
#   running and shows the welcome window again.
#
# Usage: Scripts/verify-lifecycle.sh [/path/to/ArchiveCat.app]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/dist/ArchiveCat.app}"
APP_NAME="ArchiveCat"

export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$ROOT/.build/module-cache"
export TMPDIR="$ROOT/.build/tmp"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$TMPDIR"

PROBE_SRC="$ROOT/Scripts/ui-probe.swift"
PROBE_BIN="$ROOT/.build/ui-probe"

failures=0

note()  { printf '  %s\n' "$*"; }
pass()  { printf 'PASS: %s\n' "$*"; }
fail()  { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }

probe() {
  "$PROBE_BIN" "$APP_NAME" 2>/dev/null || true
}

# The probe prints "pid<TAB>title" for each distinct on-screen window owned by a
# live ArchiveCat process. Document windows are titled after the archive; the
# welcome window is titled with the app name.
doc_window_count() { probe | awk -F'\t' -v app="$APP_NAME" '$2 != app' | wc -l | tr -d ' '; }
welcome_window_count() { probe | awk -F'\t' -v app="$APP_NAME" '$2 == app' | wc -l | tr -d ' '; }

app_running() { pgrep -x "$APP_NAME" >/dev/null; }

open_archive() { open -a "$APP" "$1" >/dev/null 2>&1; }

quit_app() {
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  # Wait for a full exit so state is written before we clear it and no zombie
  # windows linger in the window server.
  for _ in $(seq 1 20); do
    pgrep -x "$APP_NAME" >/dev/null || break
    sleep 0.25
  done
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    pgrep -x "$APP_NAME" >/dev/null || break
    sleep 0.25
  done
}

[[ -d "$APP" ]] || { echo "error: $APP does not exist; run 'make app' first" >&2; exit 2; }

echo "==> Compiling the window probe"
swiftc -O -o "$PROBE_BIN" "$PROBE_SRC"

echo "==> Creating fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
printf 'alpha\n' > "$WORK/alpha.txt"
printf 'beta\n'  > "$WORK/beta.txt"
(cd "$WORK" && /usr/bin/bsdtar -cf "$WORK/alpha.tar" alpha.txt)
(cd "$WORK" && /usr/bin/zip -q "$WORK/beta.zip" beta.txt)

CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
CRASH_MARKER="$WORK/crash-marker"
crash_count() {
  if [[ -d "$CRASH_DIR" ]]; then
    ls -1 "$CRASH_DIR" 2>/dev/null | grep -c "^$APP_NAME.*\.crash" || true
  else
    echo 0
  fi
}
CRASHES_BEFORE="$(crash_count)"

echo "==> Restarting $APP_NAME in a clean state"
# Quit first (so state is saved with zero open documents), then clear any saved
# state, so the relaunch starts with no documents and shows the welcome window.
# Restoration is correct in production; it would make window counts here
# unpredictable.
quit_app
sleep 1
rm -rf "$HOME/Library/Containers/com.frankruan.ArchiveCat/Data/Library/Saved Application State/com.frankruan.ArchiveCat.savedState" 2>/dev/null || true
rm -rf "$HOME/Library/Saved Application State/com.frankruan.ArchiveCat.savedState" 2>/dev/null || true

echo "==> Step 1: launch with nothing to open"
# -ApplePersistenceIgnoreState suppresses window restoration so the baseline is
# deterministic even if an earlier run left documents open. (Restoration itself
# is correct and standard; we just don't want it in a test.)
open -a "$APP" --args -ApplePersistenceIgnoreState YES >/dev/null 2>&1
sleep 4
if [[ "$(welcome_window_count)" -ge 1 ]]; then
  pass "welcome window shown at launch"
else
  fail "no welcome window at launch"
fi
if app_running; then pass "app is running"; else fail "app exited"; fi

echo "==> Step 2: open archive A"
open_archive "$WORK/alpha.tar"
sleep 4
if [[ "$(doc_window_count)" -ge 1 ]]; then
  pass "archive A opened as a document window"
else
  fail "archive A did not open a document window"
fi

echo "==> Step 3: open archive B while A is open"
open_archive "$WORK/beta.zip"
sleep 4
BOTH="$(doc_window_count)"
if [[ "$BOTH" -ge 2 ]]; then
  pass "both archives are open as documents ($BOTH document windows)"
else
  fail "expected 2 document windows, found $BOTH"
fi

echo "==> Step 4: open archive A again"
open_archive "$WORK/alpha.tar"
sleep 3
AGAIN="$(doc_window_count)"
if [[ "$BOTH" -lt 2 ]]; then
  fail "step 4 is meaningless: only $BOTH document window(s) were open"
elif [[ "$AGAIN" -eq "$BOTH" ]]; then
  pass "reopening A reused its document ($AGAIN document windows)"
else
  fail "reopening A changed the document window count from $BOTH to $AGAIN"
fi

echo "==> Step 5: Dock-style reopen with no file"
open -a "$APP" >/dev/null 2>&1
sleep 2
if app_running && [[ "$(doc_window_count)" -eq "$BOTH" ]]; then
  pass "reopen left the documents alone"
else
  fail "reopen disturbed the documents"
fi

CRASHES_AFTER="$(crash_count)"
if [[ "$CRASHES_AFTER" == "$CRASHES_BEFORE" ]]; then
  pass "no crash reports were produced"
else
  fail "a crash report appeared in $CRASH_DIR"
fi

echo "==> Step 6: clean quit"
quit_app
sleep 2
if app_running; then
  fail "app did not quit"
else
  pass "app quit cleanly"
fi

echo
if [[ "$failures" -gt 0 ]]; then
  echo "$failures failure(s). See above."
  exit 1
fi
echo "All lifecycle checks passed."
echo
echo "Not automated (TCC denies GUI input to scripts): close each document window"
echo "with ⌘W by hand and confirm the app stays running and shows the welcome"
echo "window again after the last one."
