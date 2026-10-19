#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$(mktemp -d)"
trap 'rm -rf "$OUTPUT"' EXIT
OBJC_LIBRARY="$(find /usr/lib/gcc -name libobjc.so -print -quit)"
test -n "$OBJC_LIBRARY"
OBJC_RUNTIME="$(dirname "$OBJC_LIBRARY")"

clang++ $(gnustep-config --objc-flags) \
  -I"$OBJC_RUNTIME/include" -L"$OBJC_RUNTIME" \
  -DYTKACE_HOOK_TEST -std=c++17 -O0 \
  "$ROOT/Tweak/Runtime/Hooking.mm" "$ROOT/Tests/hooking_runtime_test.mm" \
  -o "$OUTPUT/hooking-test" $(gnustep-config --base-libs)
"$OUTPUT/hooking-test"

clang++ $(gnustep-config --objc-flags) \
  -I"$OBJC_RUNTIME/include" -L"$OBJC_RUNTIME" -std=c++17 -O0 \
  "$ROOT/Tests/player_mute_test.mm" \
  -o "$OUTPUT/player-mute-test" $(gnustep-config --base-libs)
"$OUTPUT/player-mute-test"
