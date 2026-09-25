# Quill

**Speak anywhere. The text lands where you point.**

Tap a key, talk, then click into whatever window you want the words in. They appear there — at
the end of what's already written, without touching your clipboard.

**Double-tap it instead** and Quill translates whatever your Mac is playing — the other side of a
call, a video — live, in a panel beside it. See [Live translation](#live-translation--double-tap-control).

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

Right-click the pill (or the menu-bar icon):

- **Trigger** — `Control`, right `⌘`, right `⌥`, `🌐`, or `F5`; single tap or double tap
- **Click anywhere to insert** — the click-to-choose-destination gesture
- **Insert at end of field** — append after existing text rather than at the cursor
- **Clean up grammar** — off by default; see below
- **Stop when I say "that's it" or "that's all"** — finish a dictation by voice alone
- **Finish when I stop talking** — off, or after 2 / 3 / 5 / 8 seconds of silence
- **Language** — 26 languages including Chinese, or auto-detect (which works well — the model
  identifies the language on its own)
- **Recent** — your last 20 transcripts, click to copy
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
capitalisation, punctuation, apostrophes, the small things speech-to-text leaves behind.

```
you said:   so i was thinking maybe we could ship this on friday
you get:    So I was thinking maybe we could ship this on Friday.
```

It uses the fastest non-reasoning model, so there's no thinking time — around **0.9 seconds**,
and the connection is opened while you're still speaking so the request is already warm. Off by
default, because it costs that second and because it changes your words.

**It will not rewrite you.** The instruction is to correct and nothing else, but instructions
alone aren't enough — a dictation is often itself a question or a command, and a model asked to
tidy "what is the capital of France" might answer it instead. So the result is checked before
it's used: it has to be a similar length and keep at least 70% of your original words, or your
raw text is inserted untouched. Every other failure — network, timeout, expired session — falls
back the same way. You cannot lose your words to this feature.

## How the text gets in

Quill doesn't simulate `⌘V` and doesn't touch your clipboard.

1. It asks Accessibility for the focused element.
2. It reads what's already in that field and, if **Insert at end of field** is on, puts the caret
   after the last character. Otherwise the words go where your caret is.
3. It fits the text to what is around it: lowercases a first word that lands mid-sentence, drops a
   trailing full stop when more of the same sentence follows, and adds a space on either side if
   the words would otherwise run together — but not after an opening bracket, before a comma,
   between Chinese or Japanese characters, or where there's already a space or a line break.
4. It writes the text into the selection.

Terminals, canvases and most web views expose no editable text to Accessibility. Those fall back
to a synthetic `⌘V` — but the text is fitted and the caret is still moved first where possible,
and your previous clipboard contents are snapshotted and restored afterwards. Either way, what you
had copied is still there when it's done.

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
- Your Grok token is read fresh from `~/.grok/auth.json` at the start of each recording. Quill
  never copies, stores or transmits it anywhere except to xAI.
- Your last 20 transcripts are kept locally so you can re-copy them from the menu. They live in
  preferences as **plain text**, so if you dictate anything private, use **Recent ▸ Clear recent**
  or switch **Keep recent transcripts** off — that also wipes what's already stored.
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

Unit tests for the text fitting, the voice-command matching, the tap gesture and the live
transcript, no app or network needed:

```sh
./tests/run.sh
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
- Not notarised — see above.

## Licence

MIT. Use it for anything.
