#!/bin/bash
#
# Scripts/build-app.sh — assemble ArchiveCat.app.
#
# SwiftPM does not build .app bundles, so this script does the packaging by
# hand. It is deliberately small and boring: copy the executable, drop in
# Info.plist, bring libarchive along with its Homebrew dependencies, rewrite
# their install names to look inside the bundle, and sign.
#
# Why the dependency bundling matters: `brew install libarchive` links against
# Homebrew's lzma, zstd, lz4 and libb2, each with an absolute
# `/opt/homebrew/...` install name. An app that referenced those directly would
# only ever run on the machine that built it. Copying them into
# Contents/Frameworks and rewriting the install names makes the bundle
# self-contained.
#
# Usage:
#   Scripts/build-app.sh [--debug] [--no-bundle-deps] [--identity NAME] [--no-sandbox]
#
# Environment:
#   CODESIGN_IDENTITY   signing identity. Defaults to ad-hoc ("-").
#   ARCHIVECAT_SANDBOX  set to 0 to build without the sandbox entitlements
#                       (useful when signing with a certificate that has no
#                       team identifier).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="release"
BUNDLE_DEPS=1
IDENTITY="${CODESIGN_IDENTITY:--}"
USE_SANDBOX="${ARCHIVECAT_SANDBOX:-1}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) CONFIGURATION="debug" ;;
    --no-bundle-deps) BUNDLE_DEPS=0 ;;
    --identity) IDENTITY="$2"; shift ;;
    --no-sandbox) USE_SANDBOX=0 ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

APP_NAME="ArchiveCat"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
FRAMEWORKS="$CONTENTS/Frameworks"
EXECUTABLE="$CONTENTS/MacOS/$APP_NAME"

echo "==> Building ($CONFIGURATION)"
"$ROOT/Scripts/swift.sh" build -c "$CONFIGURATION" --product "$APP_NAME"

BIN_PATH="$("$ROOT/Scripts/swift.sh" build -c "$CONFIGURATION" --show-bin-path)"
BINARY="$BIN_PATH/$APP_NAME"
if [[ ! -x "$BINARY" ]]; then
  echo "error: built executable not found at $BINARY" >&2
  exit 1
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$FRAMEWORKS"
cp "$BINARY" "$CONTENTS/MacOS/$APP_NAME"
chmod u+w "$EXECUTABLE"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# ---------------------------------------------------------------------------
# Bundle libarchive and everything it pulls in from Homebrew.
# ---------------------------------------------------------------------------
# Prints the non-system libraries a Mach-O file links against.
homebrew_dependencies() {
  otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -E '^/(opt/homebrew|usr/local)/' || true
}

if [[ "$BUNDLE_DEPS" == "1" ]]; then
  echo "==> Bundling libarchive and its Homebrew dependencies"

  # Breadth-first over the dependency graph.
  queue=()
  while IFS= read -r dep; do [[ -n "$dep" ]] && queue+=("$dep"); done < <(homebrew_dependencies "$EXECUTABLE")

  declare -a bundled=()
  is_bundled() {
    local name="$1"
    local existing
    for existing in "${bundled[@]-}"; do
      [[ "$existing" == "$name" ]] && return 0
    done
    return 1
  }

  while [[ ${#queue[@]} -gt 0 ]]; do
    dep="${queue[0]}"
    queue=("${queue[@]:1}")
    base="$(basename "$dep")"
    is_bundled "$base" && continue

    if [[ ! -f "$dep" ]]; then
      echo "    ! missing dependency, skipped: $dep"
      continue
    fi

    cp -f "$dep" "$FRAMEWORKS/$base"
    chmod u+w "$FRAMEWORKS/$base"
    bundled+=("$base")
    echo "    $base"

    while IFS= read -r nested; do [[ -n "$nested" ]] && queue+=("$nested"); done < <(homebrew_dependencies "$dep")
  done

  # 1. Each bundled library gets an @rpath install name…
  for library in "$FRAMEWORKS"/*.dylib; do
    [[ -e "$library" ]] || continue
    base="$(basename "$library")"
    install_name_tool -id "@rpath/$base" "$library"
  done

  # 2. …and points at its bundled neighbours.
  for library in "$FRAMEWORKS"/*.dylib; do
    [[ -e "$library" ]] || continue
    while IFS= read -r dep; do
      dep_base="$(basename "$dep")"
      if [[ -f "$FRAMEWORKS/$dep_base" ]]; then
        install_name_tool -change "$dep" "@loader_path/$dep_base" "$library"
      fi
    done < <(homebrew_dependencies "$library")
  done

  # 3. The executable looks its libraries up in Contents/Frameworks.
  while IFS= read -r dep; do
    dep_base="$(basename "$dep")"
    if [[ -f "$FRAMEWORKS/$dep_base" ]]; then
      install_name_tool -change "$dep" "@rpath/$dep_base" "$EXECUTABLE"
    fi
  done < <(homebrew_dependencies "$EXECUTABLE")

  if ! otool -l "$EXECUTABLE" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE"
  fi
fi

# ---------------------------------------------------------------------------
# Sign: nested code first, then the bundle.
# ---------------------------------------------------------------------------
echo "==> Signing with identity: ${IDENTITY}"
SIGN_ARGS=(--force --timestamp=none --sign "$IDENTITY")
if [[ "$USE_SANDBOX" == "1" ]]; then
  SIGN_ARGS+=(--entitlements "$ROOT/Resources/ArchiveCat.entitlements")
else
  echo "    (sandbox entitlements disabled)"
fi

for library in "$FRAMEWORKS"/*.dylib; do
  [[ -e "$library" ]] || continue
  codesign --force --timestamp=none --sign "$IDENTITY" "$library"
done

codesign "${SIGN_ARGS[@]}" "$APP"

if codesign --verify --verbose=2 "$APP" 2>&1 | sed 's/^/    /'; then
  :
fi

echo "==> Built $APP"
