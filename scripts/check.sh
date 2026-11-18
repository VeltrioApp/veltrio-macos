#!/usr/bin/env bash
#
# What a change must pass before it's committed: the core in Generated/
# (fetched if missing), the Xcode project, and the Swift unit tests.
#
# Usage: scripts/check.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ -f Generated/Lib/libveltrio_core.dylib ] || ./scripts/fetch-core.sh

echo "==> Swift tests"
xcodegen generate --quiet
xcodebuild -project Veltrio.xcodeproj -scheme Veltrio \
  -destination "platform=macOS,arch=$(uname -m)" -quiet test

echo
echo "All checks passed."
