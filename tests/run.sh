#!/usr/bin/env bash
# Run the unit tests. Each one is a single Foundation-only binary built from the
# source file it exercises, so no Xcode project and no test framework is needed.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

echo "→ TextTidy"
swiftc -swift-version 5 -o "$OUT/texttidy" Sources/TextTidy.swift tests/TextTidyTest.swift
"$OUT/texttidy"

echo
echo "→ VoiceCommands"
swiftc -swift-version 5 -o "$OUT/commands" Sources/Commands.swift tests/VoiceCommandsTest.swift
"$OUT/commands"

echo
echo "→ TapSequence"
swiftc -swift-version 5 -o "$OUT/taps" Sources/TapSequence.swift tests/TapSequenceTest.swift
"$OUT/taps"

echo
echo "→ LiveText"
swiftc -swift-version 5 -o "$OUT/livetext" Sources/LiveText.swift tests/LiveTextTest.swift
"$OUT/livetext"
