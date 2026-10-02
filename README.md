# Quill

**Speak anywhere. The text lands where you point.**

Tap a key, talk, then click into whatever window you want the words in. They appear there — at
the end of what's already written, without touching your clipboard.

**Double-tap it instead** and Quill translates whatever your Mac is playing — the other side of a
call, a video — live, in a panel beside it. See [Live translation](#live-translation--double-tap-control).

**Open the Quill window** and there's more: **meeting notes** that tell the voices apart, jot down
what matters as the conversation moves, show who spoke when, and write up the decisions and action
items when you're done — you can ask them questions afterwards. Plus everything you've dictated,
your own vocabulary and snippets, and every setting. See [The Quill window](#the-quill-window) and
[Meeting notes](#meeting-notes).

Quill transcribes with **your existing Grok subscription**, so there's no API key to buy and
nothing metered.

---

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/xfreeze2/quill/main/install.sh | bash
```

Installs to `~/Applications`, so it never asks for your password. Quill opens and walks you
through the three things it needs.

Prefer to do it by hand? Grab `Quill.zip` from
[Releases](https://github.com/xfreeze2/quill/releases), unzip it into `~/Applications`, and run:

```sh
xattr -dr com.apple.quarantine ~/Applications/Quill.app && open ~/Applications/Quill.app
```

That last step is needed because Quill isn't notarised by Apple — macOS quarantines anything
downloaded from the internet. See [Why the quarantine step](#why-the-quarantine-step).

### Windows

```powershell
irm https://raw.githubusercontent.com/xfreeze2/quill/main/windows/install.ps1 | iex
```

Installs to `%LOCALAPPDATA%\Quill` — no admin. Same tap-Control-and-talk behaviour as
the Mac app, including "open Grok" into Windows Terminal. Details in
[windows/README.md](windows/README.md).

## Use it

1. **Tap `Control`** — a panel appears in the corner and starts listening.
2. **Talk.** The transcript streams in live as you speak.
3. **Finish, any way you like — or just stop talking:**
   - **say nothing for 5 seconds** — it finishes on its own and pastes. Adjustable, or off
   - **say "that's it"** or **"that's all"** — Quill stops and pastes; the phrase itself is never included
   - **click wherever you want the words** — the click both stops it and chooses the destination
   - **tap `Control` again** — lands them where your cursor already is
   - **press `Escape`** — throws the whole thing away and pastes nothing

**Replacing text:** highlight something first, then dictate — what you say replaces the
selection instead of being appended. The highlight is captured the moment you press the trigger,
so it survives you clicking elsewhere afterwards.

The finish phrase only stops when it is the *last* thing you say and nothing follows for a moment,
so ordinary speech like "that's it exactly" or "that's all I need from you" will not cut you off.
Turn it off in the menu if you'd rather.

The corner pill is clickable too, if you'd rather use the mouse for both ends. **Drag it to any
edge** and it snaps flush and stays there — the panel then opens inward from that edge, so it
never sweeps across your screen. With more than one display, drag it onto whichever one you want;
it follows the pointer across and remembers that display between launches.

You can start a new dictation while the previous one is still finishing. The earlier words land
where they were meant to when they arrive; the panel belongs to the new recording.

**Mid-sentence dictation reads as one sentence.** Speech-to-text capitalises the first word of
everything it hears, which is right at the start of a sentence and wrong in the middle of one. If
the words land after an unfinished sentence — `so I was thinking |` — the first word is lowercased,
and a full stop the service tacked on is dropped when the rest of your sentence follows the caret.
Names, `I`, acronyms and days and months keep their capitals; at the start of a line, a list item,
or after a full stop nothing is changed. German, which capitalises nouns, is left alone.

## The Quill window

Quill lives in the menu bar, and opens as a proper Mac app when you want one: click **Open Quill**
in the menu-bar menu, or just launch it. It shows in the Dock while the window is open and goes
back to being quiet when you close it. A meeting you're recording carries on in the menu bar (the
icon turns red).

Three things to do, and settings:

| | |
|---|---|
| **Meetings** | A list of your meetings beside the one you're reading. Start a new one, watch it live, then read the summary, the transcript, ask it questions, and keep your own notes. |
| **Dictation** | **History** — everything you've dictated, by day, searchable. **Vocabulary** — names and terms to spell your way, and **shortcuts**: say "my email", get the whole address. |
| **Translation** | Start live translation and choose the language, what to listen to, and whether it hides from screen sharing. |
| **Settings** | Your account, the permissions that are still missing, and short sections for dictation, meetings and general. The rarely-touched options are under **Advanced**. |

⌘1–⌘3 switch sections, ⌘, opens Settings, ⌘N opens a new meeting.

**Shortcuts (snippets).** Add a phrase and what it should become under **Dictation ▸ Vocabulary**.
When a dictation is exactly that phrase — or contains it — Quill writes the expansion. Matching
ignores case and the punctuation the transcriber puts around it, a phrase only matches whole words,
and a longer phrase wins over a shorter one inside it. Expansion happens after grammar cleanup, so
what you wrote is never reworded.

## Meeting notes

Open **Meetings** and press the new-meeting button, or ⌘N (or **Start meeting notes** in the menu-bar menu) and pick what you're
capturing:

- **A call on this Mac** — your microphone is *you*; everything the Mac plays is everyone else.
  Quill tells the other voices apart.
- **People in the room** — one microphone, and Quill tells the voices apart.

While it runs, a strip across the top shows **who is in the conversation and who is talking right
now**, with each person's share of the talk. Every minute or so Quill jots **live notes** — a few
short lines on what was just discussed or decided — so you can see the shape of the meeting as it
happens (turn this off under **Settings ▸ Meetings**). **Transcript** shows every line as it's said.
The voices are numbered at first (Speaker 1, Speaker 2…). **Your notes** beside it is yours: jot
what matters, and it's kept with the meeting and used in the summary.

When you stop, Quill writes the **summary**: an overview, **decisions**, **action items with
owners** (tick them off), **topics** with the time each began, key points, and open questions. A
**conversation map** shows each person's turns along the meeting's length with the topics marked on
it — click anywhere on it to jump there (it plays the recording if you kept one, otherwise it takes
you to that moment in the transcript). The title is filled in from what was said, unless you named
it. If the summary spots a name in the conversation — "thanks, Daniel" — it offers it for that
voice; you accept or ignore it. Rename a voice yourself any time by clicking its name; everything
follows. **Copy notes** puts the summary on the clipboard; the **…** menu copies the transcript,
exports Markdown, or writes the summary again.

**Ask** answers questions from the meeting — "what did I agree to do?", "what's still
unresolved?" — using only what was said, and can **draft a follow-up email**.

**Sound is optional and off by default.** Switch on *Also keep the sound* for a meeting, or make it
the default under **Settings ▸ Meetings** (which asks you to confirm). The recording is a compact
`.m4a` stored only on your Mac next to the notes (about 14 MB an hour); play it back in the
meeting, click any line of the transcript to jump to it, and delete the recording without losing
the transcript. Tell people they're being recorded — the laws about it vary.

Everything is kept as text first: the transcript is saved every ten seconds as it goes, so a crash
or a closed lid loses seconds, not the meeting. A meeting cut short is recovered, with its sound,
the next time Quill opens.

Details worth knowing:

- Hearing the other side of a **call** needs macOS 14.2 or newer and the same System Audio
  permission as live translation. Without it Quill says so and listens to the microphone only.
- **Headphones give the cleanest notes.** On speakers, the microphone hears the call too. Quill
  removes that echo from your line when it's clear enough to match, so "You" doesn't repeat what the
  others said — but a faint or garbled echo can slip through.
- Voices are told apart within one connection. On a very long meeting Quill moves to a fresh
  connection during a pause, and that voice may come back as a new number. Give both the same
  name and the transcript reads them as one person.
- Summaries are written by Grok from the transcript and your notes. They can be wrong; the
  transcript is always there to check against. Very long meetings are summarised in parts and
  joined.

### Live translation — double-tap Control

**Double-tap `Control`** and a two-card panel opens in the top-right corner: on top, what is
being said, as it is said; below, what it means, in your language. It listens to **everything
your Mac plays** — the other side of a Zoom, Meet, Teams, FaceTime, Slack or WhatsApp call, a
video, a browser tab — so whoever is speaking, in whatever language, you can read along.
Press **Escape**, double-tap again, or click ✕ to close it. A single tap still dictates, exactly
as before — and while you dictate over an open translator, Escape throws away the dictation
first; a second press closes the translator.

- **Nothing to set up per call.** The language is detected on its own, and it can change mid-call:
  Spanish, then Japanese, then English all come out right, each in its own script.
- **Live, not after the fact.** A long sentence is translated while it is still being spoken, and
  settled within two seconds of the speaker finishing it.
- **Speech already in your language** is shown as it is rather than sent to be "translated".
- **Translation only** — the ▭ button hides the top card if you only want the meaning.
- **Pick the language** — click the language name on the bottom card; it re-translates the last
  sentences straight away. **System audio ▾** switches to the microphone instead.
- **Copy** — the ⧉ button copies the whole session, original and translation paired.
- **It never takes focus.** Clicks on the panel don't pull the keyboard away from your call, and it
  follows you onto a full-screen call's own Space.
- **Kept out of screen shares.** macOS is asked to leave the panel out of screen sharing and
  recordings, so the people on the call don't watch you read the translation. Switch that off
  under **Live translation ▸ Hide from screen sharing** if you want to share it.

**Why it can hear every call.** Quill uses the macOS system-audio tap, which reads the mix below
every app. An app can hide its *windows* from screen capture, but there is no way for it to opt
out of this — a call is just audio being played. Audio headed for AirPods or any other output is
caught the same way, and plugging headphones in mid-call rebuilds the tap on its own. The one
exception is DRM video (Netflix, Apple TV+ in Safari), which macOS itself silences for every
recorder; calls are never protected that way.

**How it stays accurate.** The speech service locks onto the first language it hears on a
connection and can mishear a different one after it — a Spanish connection once wrote Japanese as
Spanish-sounding nonsense, and another time dropped an English sentence entirely. Quill watches
for both: words written in a different language from the one spoken, and seconds of speech that
never came back as words. Either way it replays that stretch — it keeps the last 40 seconds — to a
fresh connection set to the right language, and swaps in the corrected sentence. Long calls are
moved to a fresh connection during a pause every few minutes, so no sentence is ever split
between two.

The first time, macOS asks whether Quill may record system audio. If you declined, the panel
says so and has a button to the right Settings pane: **Privacy & Security ▸ Screen & System Audio
Recording ▸ System Audio Recording Only**. Needs macOS 14.2 or newer; on older systems the panel
offers the microphone instead.

Double-tapping only exists as its own gesture while the trigger is a *single* tap (the default).
If you use double-tap to dictate, open live translation from the menu instead.

### Say "open Grok" to start

Say **"open Grok"** or **"open Grok Build"** as the *first* thing in a dictation and Quill opens a
Grok Build session *without stopping the recording* — so you can carry straight on and have the
rest become your prompt:

> "open Grok Build, then write me a haiku about rockets"

…opens Grok and types only `then write me a haiku about rockets`. **The command phrase is
removed from the inserted text**, so it never ends up in a prompt. Speech-to-text mishearings
("grog", "grock", "croc") are matched too.

If you say it in the middle of a sentence — "I think we should open Grok and try that" — it is
left alone. Those words stay in the transcript and nothing launches.

It opens a new window in the Ghostty you already have (⌘N), or launches Ghostty if it is not
running, then types `grok` — the same thing as doing it by hand, so your theme, scrollback and
copy/paste all behave exactly as usual. It does **not** start a second copy of Ghostty; that
instance looks wrong and cannot select or copy.

After Grok opens, clicks in that window are yours again — select, copy, scroll — they no longer
end the dictation. The rest of what you said still becomes the prompt when you pause, say
"that's it", or tap the trigger.

## What you need

| | |
|---|---|
| **macOS 12 or newer, or Windows 10 1809+ / Windows 11 (64-bit)** | Mac is universal (Apple Silicon and Intel). Windows is a self-contained `Quill.exe`. |
| **A Grok subscription _or_ an xAI API key** | Quill uses the login the `grok` CLI already stores. No subscription? Add your own key from [console.x.ai](https://console.x.ai) and usage is billed to your account. |
| **Microphone access** | Asked for on first use |
| **Accessibility access** | So the trigger key works, and so Quill can type into other apps |
| **System audio recording** *(optional)* | Only for live translation of calls and videos. macOS 14.2+ |

The setup window shows all of these live, with a button next to whatever isn't ready. It reopens
from the menu any time.

> **If only the corner pill responds and the keyboard does nothing, that's always Accessibility.**
> macOS lets an app create a keyboard listener without permission and then simply never sends it
> anything. Quill turns its pill **amber** when this is the case — click it and it takes you
> straight to the right settings pane.

## Settings

Everything below is also in the window — **Settings**, with live translation's options on the
**Translation** screen. Or right-click the pill (or the menu-bar icon):

- **Trigger** — `Control`, right `⌘`, right `⌥`, `🌐`, or `F5`; single tap or double tap
- **Click anywhere to insert** — the click-to-choose-destination gesture
- **Insert at end of field** — append after existing text rather than at the cursor
- **Clean up grammar** — off by default; see below
- **Vocabulary & notes…** — names and terms for cleanup to spell your way; see below
- **Stop when I say "that's it" or "that's all"** — finish a dictation by voice alone
- **Finish when I stop talking** — off, or after 2 / 3 / 5 / 8 seconds of silence
- **Language** — 26 languages including Chinese, or auto-detect (which works well — the model
  identifies the language on its own)
- **Open Quill** — the window · **Start meeting notes** — begin or end one from anywhere
- **Recent** — your latest dictations, click to copy; **Show all…** opens the history
- **Live translation** — start or stop it; **Translate into** (26 languages, English by default);
  **Listen to** system audio or the microphone; **Show only the translation**; **Hide from screen
  sharing** (on); **Double-tap Control to open** (on); **Copy last session**
- **Appearance** — "Show idle pill" (hide the resting dot entirely; the trigger key, menu-bar icon
  and the session bar while dictating all keep working) and "Reset panel position"
- **Notify about updates** — checks GitHub once a day, never during a recording; **Check for
  updates…** does it on demand. Never downloads or installs anything itself — it points you at
  the same install command, because Quill is self-signed and not notarised, and an app quietly
  replacing its own binary is the same behaviour malware uses to persist. The check uses GitHub's
  ordinary release-page redirect rather than the REST API, so it isn't subject to the 60
  requests/hour/IP limit that API calls share with everything else on your network — if that path
  is ever unreachable it falls back to the API and gives an honest "rate limited, try again in Nm"
  rather than a bare HTTP code.
- **Start at login**

### About the trigger key

Bare modifier taps are used deliberately: a modifier pressed on its own means nothing to macOS or
to any app, so it can't shadow a shortcut in whatever you're typing into.

Chords are filtered out without needing Input Monitoring. Rather than watching the keypress inside
`⌃C` — which requires that permission — Quill samples the system's input-activity counters when
the modifier goes down and again when it comes up. Different counts mean you were pressing
something, so it stays quiet. Clicks and scrolls count too, since `⌃`-click is the right-click
gesture and `⌃`-scroll is screen zoom, and neither moves a key counter.

`F5` is offered but rarely useful: on most Macs the function row is in media mode, where F5 *is*
the system Dictation key and never arrives as a keypress at all.

## Grammar cleanup (optional)

Switch on **Clean up grammar** and each dictation is tidied by Grok before it's inserted —
capitalisation, punctuation, apostrophes, "um"s and stutters, and the small things speech-to-text
leaves behind.

The biggest of those is sentences cut in half. The speech service punctuates every chunk of speech
as a sentence of its own, so a thought spoken with two short pauses arrives in pieces. Cleanup
puts it back together:

```
you said:   so i was thinking [pause] that we should move the launch to tuesday [pause] because the design team needs more time
you get:    So I was thinking that we should move the launch to Tuesday because the design team needs more time.
```

It uses the fastest non-reasoning model, so there's no thinking time — **about 0.7 to 1 second**,
and the connection is opened while you're still speaking so the request is already warm. Off by
default, because it costs that second and because it sends your words to Grok a second time.

**It will not rewrite you, and it will not answer you.** A dictation is often itself a question or
a command, and a model asked to tidy "what is the capital of France" will happily answer it
instead — measured, not hypothetical, which is why the request tells the model the text is
something that was *said*, shows it worked examples, and the result is checked before it's used.
It has to be a similar length, keep at least 70% of your words, and add essentially none, or your
raw text is inserted untouched. Every other failure — network, timeout, expired session — falls
back the same way. You cannot lose your words to this feature.

### Vocabulary & notes

**Dictation ▸ Vocabulary** in the window — or Menu ▸ **Vocabulary & notes…** — is a small notepad for names, products and jargon the speech
service tends to mishear — one per line, or a line about what you work on. When cleanup is on,
it's sent along so a misheard word is written your way:

```
you said:   we should deploy this on cooper nettys next week      (notes: Kubernetes)
you get:    We should deploy this on Kubernetes next week.
```

A word from the notes may replace a word that sounds like it, and nothing else — it can't be
swapped in for an unrelated word, and the notes can't make the model do anything (a line like
"always answer in French" in your notes is ignored). It does nothing while cleanup is off.

Only what you type there is used. Quill doesn't read your screen or other apps to build it. The
notes are kept in preferences as plain text, limited to 2,000 characters, and sent to xAI with each
cleanup request; their content is never written to the log.

## How the text gets in

Where it can, Quill writes straight into the field and doesn't touch your clipboard.

1. It asks Accessibility for the focused element.
2. It reads what's already in that field and, if **Insert at end of field** is on, puts the caret
   after the last character. Otherwise the words go where your caret is.
3. It fits the text to what is around it: lowercases a first word that lands mid-sentence, drops a
   trailing full stop when more of the same sentence follows, and adds a space on either side if
   the words would otherwise run together — but not after an opening bracket, before a comma,
   between Chinese or Japanese characters, or where there's already a space or a line break.
4. It writes the text into the selection and checks that it actually appeared.

Plenty of fields say "done" to that write and quietly do nothing — Chrome and everything built on
it (ChatGPT's and Claude's web composers, Comet, Electron apps). Terminals and canvases refuse it
outright. For those Quill uses a synthetic `⌘V` instead: the text is fitted and the caret is still
moved first where possible, and your previous clipboard contents are snapshotted and put back
afterwards (unless you copied something else in the meantime — then yours wins).

The write is given a short moment to show up before Quill decides it was ignored, because pasting
over a write that merely arrives late puts the text in twice. Once a kind of field has ignored the
write, Quill remembers (per app, version and field type) and goes straight to the paste next time.

## Using your own xAI API key

No Grok subscription? Choose **Use my own xAI API key…** from the menu and paste a key from
[console.x.ai](https://console.x.ai). Quill checks it against xAI before saving, so a typo shows
up straight away rather than mid-dictation. If both a key and a Grok session are present, the key
wins — you chose it deliberately.

**How the key is handled**

- Stored in your Mac's **Keychain**, never in preferences. A value in `UserDefaults` becomes a
  plist under `~/Library/Preferences` that any process running as you can read, and it would be
  swept into backups and sync. A billable credential has no business sitting there.
- Marked `WhenUnlockedThisDeviceOnly`: unreadable while the Mac is locked, never carried to
  another machine by iCloud Keychain, never restored from a backup onto different hardware.
- Entered in a secure field, so it is never drawn on screen or captured by a screenshot.
- **Never written to the log.** Only whether a save or a check succeeded, and the HTTP status.
- Only ever sent to `api.x.ai`, over TLS.
- Remove it any time from the same menu item.

## Privacy

- Your audio is streamed to xAI's speech-to-text service to be transcribed. Nothing goes anywhere
  else.
- **Live translation** streams what your Mac plays — only while the panel is open — to the same
  service, and each sentence to Grok to be translated. The menu bar shows macOS's purple
  recording dot for as long as it listens. A session is kept in memory only, for **Copy**, and
  is never written to disk or to the log; the log records counts and timings, never words.
- **Grammar cleanup**, if you switch it on, sends each finished transcript — and your **Vocabulary &
  notes**, if you've written any — to Grok's chat service. Off by default. The log records only
  that it ran and how long it took.
- Your Grok token is read fresh from `~/.grok/auth.json` at the start of each recording. Quill
  never copies, stores or transmits it anywhere except to xAI.
- Your dictations are kept locally so you can find them again, in a private file
  (`~/Library/Application Support/Quill/history.json`, readable only by you). If you dictate
  anything private, delete them from **Dictations**, **Recent ▸ Clear recent**, or switch **Keep
  recent transcripts** off so nothing new is kept.
- **Meeting notes** stream your microphone — and, for a call, what your Mac plays — to the same
  speech service while a meeting runs, and send the finished transcript and your notes to Grok's
  chat service to write the summary. The notes and any sound you chose to keep live in
  `~/Library/Application Support/Quill/Meetings/`, readable only by you, and nowhere else. The
  log records counts and timings, never words.
- Quill does **not** log keystrokes. A debug trail exists for troubleshooting the trigger key and
  stays off unless you explicitly turn it on.
- `~/Library/Logs/Quill.log` records what it did — which app it wrote into, and whether the text
  landed. It records **no transcript content and no credentials**: a replaced selection is logged
  as a character count, never its text. The file is capped so it can't accumulate indefinitely.

## Why the quarantine step

Quill is signed, but with a self-signed certificate rather than an Apple Developer one, and it
isn't notarised. macOS quarantines anything downloaded from the internet and refuses to open apps
it can't trace to a paid Apple developer account — usually with a misleading "damaged" message.

The install script strips that quarantine flag for you. Removing it is your decision to trust this
app, the same decision Homebrew makes on your behalf for every cask you install. If you'd rather
not, build from source instead — locally built apps are never quarantined.

## Build from source

```sh
git clone https://github.com/xfreeze2/quill && cd quill
./signing/install-identity.sh   # once per machine
./build.sh
open -a Quill
```

No Xcode project and no dependencies — `swiftc` against Cocoa and AVFoundation, assembled into a
bundle by `build.sh`.

Windows, cross-compiled from this repo (does not rebuild or restart the Mac app):

```sh
cd windows && ./build.sh
```

That produces `windows/dist/Quill-windows-x64.zip`. See [windows/README.md](windows/README.md).

`install-identity.sh` creates a local self-signed certificate so the app's code identity stays
stable between builds. That matters more than it sounds: with ad-hoc signing macOS treats every
rebuild as a brand-new app, silently drops your Accessibility and Microphone grants, and leaves
the old entries sitting in System Settings still looking enabled. The certificate lives in its own
keychain, so builds never prompt for your password.

Verify the transcription path without a microphone:

```sh
# 16 kHz mono PCM16: ffmpeg -i in.wav -ar 16000 -ac 1 -f s16le out.pcm
QUILL_SELFTEST=out.pcm ~/Applications/Quill.app/Contents/MacOS/Quill
# …and also insert the result into whatever field is focused, then read it back:
QUILL_SELFTEST=out.pcm QUILL_SELFTEST_INSERT=1 ~/Applications/Quill.app/Contents/MacOS/Quill
```

Live translation, headlessly — a file, or whatever the Mac is playing:

```sh
QUILL_SELFTEST_LIVE=out.pcm ~/Applications/Quill.app/Contents/MacOS/Quill
QUILL_SELFTEST_LIVE=system QUILL_SELFTEST_LIVE_SECONDS=40 open -n -a Quill   # prints to its stderr
```

Each translated sentence is printed as it lands, then the panel's final contents in order.
`QUILL_SELFTEST_LIVE_SNAPSHOT=<dir>` also saves the panel's pixels mid-sentence and at the end;
`QUILL_TRACE_LIVE=1` and `QUILL_TRACE_STT=1` print every segment and every raw service message.

Meeting notes, headlessly — two audio lanes in (your microphone, then the call), the transcript
and summary out:

```sh
./tests/make-fixtures.sh   # includes a three-person meeting, as meeting-mic.pcm and meeting-system.pcm
QUILL_SELFTEST_MEETING=build/fixtures/meeting-mic.pcm:build/fixtures/meeting-system.pcm \
  QUILL_SELFTEST_KEEP_AUDIO=1 ~/Applications/Quill.app/Contents/MacOS/Quill
```

Every screen of the window, drawn offscreen into PNGs in light and dark — from invented data, so
nothing of yours is read — and optionally a whole meeting run through the window's own model:

```sh
QUILL_SELFTEST_UI=/tmp/quill-ui ~/Applications/Quill.app/Contents/MacOS/Quill
QUILL_SELFTEST_UI=/tmp/quill-ui QUILL_SELFTEST_UI_MEETING=build/fixtures/meeting-mic.pcm:build/fixtures/meeting-system.pcm …
```

`QUILL_DATA_DIR=<folder>` points any run at a scratch folder instead of Application Support. The
app icon is drawn by `swift tools/make-icon.swift`.

Unit tests for the text fitting, the voice-command matching, the tap gesture, how a dictation and
a live session are assembled from the service's messages, the grammar-cleanup safety check, the
notes, the history, snippets, and everything about a meeting — who said what, echo removal, the
summary prompt and parser, the saved files and the audio recording — no app or network needed:

```sh
./tests/run.sh
```

Checks against the real thing (each needs the built app; the first two need Accessibility and a
visible window and put a test phrase into Chrome and TextEdit, then report how many copies landed):

```sh
./tests/insert-web.sh                     # a phrase into web fields and a native one — expects exactly one copy each
./tests/make-fixtures.sh                  # spoken test clips into build/fixtures (run after each build)
QUILL_SELFTEST=build/fixtures/short.pcm build/Quill.app/Contents/MacOS/Quill
QUILL_SELFTEST_POLISH=tests/fixtures/polish-cases.txt build/Quill.app/Contents/MacOS/Quill
QUILL_SELFTEST_POLISH=tests/fixtures/polish-notes-cases.txt \
  QUILL_SELFTEST_POLISH_NOTES=tests/fixtures/polish-notes.txt build/Quill.app/Contents/MacOS/Quill
QUILL_SELFTEST_FORCE_POLISH=1 QUILL_SELFTEST=build/fixtures/short.pcm …     # whole pipeline, cleanup on
```

## Known limits

- Settings live per-machine and don't sync.
- A recording stops itself after 5 minutes. If nothing has come back after 10 seconds while the
  microphone is clearly working, Quill reconnects once and replays what it heard; if that fails
  too, it tells you which part broke — microphone, network, or the service.
- If the connection drops mid-dictation, Quill reconnects once with the audio replayed. If it
  drops again, whatever was transcribed so far is inserted rather than thrown away.
- If your Grok token has expired and `grok` isn't running to refresh it, Quill says so rather than
  failing quietly.
- Meeting notes: speaker labels are the speech service's best guess. Two people with similar voices
  can be merged, and someone talking over another may be missed. Crosstalk and a distant microphone
  are the usual causes.
- Meeting notes need the network while recording; a dropped connection is retried and replays
  what it missed, but a long outage leaves a gap in the transcript. The sound, if kept, has no gap.
- A recording uses whichever microphone macOS is set to use; Quill doesn't pick one.
- Not notarised — see above.

## Licence

MIT. Use it for anything.
