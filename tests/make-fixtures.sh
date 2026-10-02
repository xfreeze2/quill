#!/usr/bin/env bash
# Spoken test clips as 16 kHz mono PCM16 — what QUILL_SELFTEST=<file> streams in
# place of the microphone. Written to build/fixtures (build.sh clears build/, so
# run this after a build).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/fixtures
mkdir -p "$OUT"

clip() {
  local name="$1" text="$2" voice="${3:-Samantha}"
  say -v "$voice" -o "$OUT/$name.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$OUT/$name.aiff" "$OUT/$name.wav"
  python3 - "$OUT/$name.wav" "$OUT/$name.pcm" <<'PY'
import sys, wave
w = wave.open(sys.argv[1])
open(sys.argv[2], "wb").write(w.readframes(w.getnframes()))
PY
}

# Long pauses between sentences: every chunk closes on its own.
clip pause "Please send the report to Maria by Friday afternoon. [[slnc 1800]] Also remind her about the budget meeting next week. [[slnc 1500]] Thanks a lot."
# Short pauses inside one sentence: chunks close mid-thought, and the drafts of
# each chunk used to be left behind as stray fragments.
clip short "So I was thinking [[slnc 700]] that we should move the launch to Tuesday, [[slnc 650]] because the design team needs more time, [[slnc 800]] and honestly I would rather ship something polished than something rushed. [[slnc 600]] What do you think about that?"
# Another language, for live translation: the "heard" label and the translation.
clip spanish "Buenos días a todos. [[slnc 900]] Hoy quiero hablar de los resultados del trimestre. [[slnc 900]] Las ventas subieron un doce por ciento, y los clientes están más contentos que nunca. [[slnc 900]] Pero todavía tenemos mucho trabajo por delante." "Eddy (Spanish (Spain))"

# A call between three people, as two audio lanes the way Quill captures one:
# the microphone (the user, "you") and the Mac's audio (two other people). Turns
# are placed one after another with a short gap, each on its own lane, silence
# elsewhere, so both files are the same length and line up in time.
meeting() {
  local i=0 plan=()
  while IFS='|' read -r lane voice text; do
    [ -z "$lane" ] && continue
    say -v "$voice" -o "$OUT/turn$i.aiff" "$text"
    afconvert -f WAVE -d LEI16@16000 -c 1 "$OUT/turn$i.aiff" "$OUT/turn$i.wav"
    plan+=("$lane:$OUT/turn$i.wav")
    i=$((i + 1))
  done
  python3 - "$OUT" "${plan[@]}" <<'PY'
import sys, wave, array
out, turns = sys.argv[1], sys.argv[2:]
rate, gap = 16000, int(1.3 * 16000)
lanes = {"mic": array.array("h"), "system": array.array("h")}
for turn in turns:
    lane, path = turn.split(":", 1)
    w = wave.open(path)
    samples = array.array("h", w.readframes(w.getnframes()))
    length = len(samples) + gap
    for name, track in lanes.items():
        track.extend(samples if name == lane else array.array("h", [0] * len(samples)))
        track.extend(array.array("h", [0] * gap))
for name, track in lanes.items():
    open(f"{out}/meeting-{name}.pcm", "wb").write(track.tobytes())
print(f"meeting: {len(lanes['mic']) / rate:.0f}s on each lane")
PY
}
meeting <<'TURNS'
system|Karen|Okay, let's get started. The goal today is to decide the launch date.
system|Daniel|I think Tuesday works, but the design team needs two more days.
mic|Samantha|Two more days sounds reasonable to me. Let's go with Thursday.
system|Karen|Good. Daniel, please send the updated schedule to everyone by tomorrow.
system|Daniel|Sure. I will also check with legal about the privacy notice.
mic|Samantha|I will write up the notes and share them this afternoon.
system|Karen|One open question: do we need a beta? Let's decide next week.
TURNS
echo "fixtures in $OUT"
