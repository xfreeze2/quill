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
echo "→ DictationText"
swiftc -swift-version 5 -o "$OUT/dictation" Sources/DictationText.swift tests/DictationTextTest.swift
"$OUT/dictation"

echo
echo "→ PolishGuard"
swiftc -swift-version 5 -o "$OUT/polishguard" Sources/PolishGuard.swift tests/PolishGuardTest.swift
"$OUT/polishguard"

echo
echo "→ ContextNotes"
swiftc -swift-version 5 -o "$OUT/notes" Sources/ContextNotes.swift tests/ContextNotesTest.swift
"$OUT/notes"

echo
echo "→ LiveText"
swiftc -swift-version 5 -o "$OUT/livetext" Sources/LiveText.swift tests/LiveTextTest.swift
"$OUT/livetext"

echo
echo "→ DictationHistory"
swiftc -swift-version 5 -o "$OUT/history" Sources/DictationHistory.swift tests/Check.swift tests/DictationHistoryTest.swift
"$OUT/history"

echo
echo "→ Snippets"
swiftc -swift-version 5 -o "$OUT/snippets" Sources/Snippets.swift tests/Check.swift tests/SnippetsTest.swift
"$OUT/snippets"

echo
echo "→ Meetings"
swiftc -swift-version 5 -o "$OUT/meeting" Sources/DictationHistory.swift Sources/Meeting.swift Sources/MeetingTranscript.swift Sources/MeetingSummary.swift Sources/MeetingTimeline.swift Sources/LiveNotes.swift Sources/MeetingAsk.swift Sources/AppSearch.swift tests/Check.swift tests/MeetingTest.swift
"$OUT/meeting"

echo
echo "→ AudioArchive"
swiftc -swift-version 5 -parse-as-library -o "$OUT/archive" Sources/DictationHistory.swift Sources/AudioArchive.swift tests/Check.swift tests/AudioArchiveTest.swift
"$OUT/archive"
