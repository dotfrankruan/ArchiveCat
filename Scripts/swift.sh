#!/bin/bash
#
# Scripts/swift.sh — run SwiftPM with all caches inside the workspace.
#
# Why this exists
# ---------------
# SwiftPM, the Clang importer and the Swift module cache all default to
# `$HOME/Library/...` and `$TMPDIR`. That is fine on a normal developer machine,
# but it breaks in sandboxed or CI environments where only the repository is
# writable, and it makes builds non-reproducible across machines.
#
# Every path below is therefore pinned to `.build/` inside the repository.
# `make build`, `make test` and `make run` all use this wrapper.
#
# Usage: Scripts/swift.sh build [args...]
#        Scripts/swift.sh test  [args...]
#        Scripts/swift.sh run   [args...]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFT_MODULECACHE_PATH="$ROOT/.build/module-cache"
export TMPDIR="$ROOT/.build/tmp"

mkdir -p "$CLANG_MODULE_CACHE_PATH" "$TMPDIR"

command="${1:-build}"
shift || true

case "$command" in
  build|test|run)
    exec swift "$command" \
      --cache-path "$ROOT/.build/cache" \
      --config-path "$ROOT/.build/config" \
      --security-path "$ROOT/.build/security" \
      --scratch-path "$ROOT/.build/scratch" \
      --disable-sandbox \
      "$@"
    ;;
  *)
    exec swift "$command" "$@"
    ;;
esac
