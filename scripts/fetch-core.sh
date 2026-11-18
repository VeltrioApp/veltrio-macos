#!/usr/bin/env bash
#
# Put the Rust core into Generated/ (gitignored), where project.yml expects it:
#
#   Generated/Lib/libveltrio_core.dylib
#   Generated/Bindings/{veltrio.swift, veltrioFFI.h, module.modulemap}
#
# By default it downloads `veltrio-core-macos.zip` from the veltrio-core
# release named in core.version (needs `gh` signed in with access to
# VeltrioApp/veltrio-core, or GH_TOKEN in CI).
#
# VELTRIO_CORE_DIR=../veltrio-core builds from a local checkout instead,
# for working on the core and the app together. VELTRIO_ARCHS=arm64 makes
# that build single-arch.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Generated"
VERSION="$(tr -d '[:space:]' < "$ROOT/core.version")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -n "${VELTRIO_CORE_DIR:-}" ]; then
  CORE="$(cd "$VELTRIO_CORE_DIR" && pwd)"
  echo "==> Building the core from $CORE"
  "$CORE/scripts/package-macos.sh"
  cp "$CORE/dist/veltrio-core-macos.zip" "$TMP/"
else
  echo "==> veltrio-core $VERSION"
  gh release download "$VERSION" --repo VeltrioApp/veltrio-core \
    --pattern veltrio-core-macos.zip --dir "$TMP"
fi

rm -rf "$OUT" && mkdir -p "$OUT"
unzip -q "$TMP/veltrio-core-macos.zip" -d "$OUT"
echo "==> Generated/ ready ($(lipo -archs "$OUT/Lib/libveltrio_core.dylib"))"
