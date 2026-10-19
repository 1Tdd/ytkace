#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$(mktemp -d)"
trap 'rm -rf "$OUTPUT"' EXIT

clang++ $(gnustep-config --objc-flags) \
  -I"$(gcc -print-file-name=include)" \
  -DYTKACE_HOOK_TEST -std=c++17 \
  "$ROOT/Tweak/Runtime/Hooking.mm" "$ROOT/Tests/hooking_runtime_test.mm" \
  -o "$OUTPUT/hooking-test" $(gnustep-config --base-libs)
"$OUTPUT/hooking-test"

clang++ $(gnustep-config --objc-flags) \
  -I"$(gcc -print-file-name=include)" -std=c++17 \
  "$ROOT/Tests/player_mute_test.mm" \
  -o "$OUTPUT/player-mute-test" $(gnustep-config --base-libs)
"$OUTPUT/player-mute-test"
