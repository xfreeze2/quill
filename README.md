# Quill

**Speak anywhere on your Mac. The text lands where you point.**

Tap a key, talk, then click into whatever window you want the words in. They appear there — at
the end of what's already written, without touching your clipboard.

Quill transcribes with **your existing Grok subscription** (nothing metered), or with an
**xAI API key** if you prefer bring-your-own-key billing.

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
never sweeps across your screen.

### Say "open Grok" while you're talking

Say **"open Grok"** or **"open Grok Build"** mid-sentence and Quill opens a Grok Build session for
you *without stopping the recording* — so you can carry straight on and have the rest become your
prompt:

> "open Grok Build, then write me a haiku about rockets"

…opens Grok and types only `then write me a haiku about rockets`. **The command phrase is always
removed from the inserted text**, so it can never end up in a prompt. Speech-to-text mishearings
("grog", "grock", "croc") are matched too.

It opens Ghostty if you have it, otherwise Terminal, using an ordinary new window running a normal
login shell — the same thing as opening a terminal and typing `grok` yourself, so your theme,
scrollback and copy/paste all behave exactly as usual.

## What you need

| | |
|---|---|
| **macOS 12 or newer** | Universal — Apple Silicon and Intel |
| **Grok subscription *or* xAI API key** | Subscription: the login the `grok` CLI stores in `~/.grok/auth.json`. API key: `XAI_API_KEY` / `GROK_CODE_XAI_API_KEY`, or one line in `~/.config/xai/api_key` (needed when Quill is launched from the Dock — GUI apps don't see your shell env). |
| **Microphone access** | Asked for on first use |
| **Accessibility access** | So the trigger key works, and so Quill can type into other apps |

The setup window shows all of these live, with a button next to whatever isn't ready. It reopens
from the menu any time.

### xAI API key (optional)

If you don't have a Grok subscription — or you'd rather bill STT to a console key — drop the key
in one of these places (first match wins after a live subscription token):

```sh
# shell (picked up only when Quill is launched from a terminal)
export XAI_API_KEY=xai-...

# file — also works for Dock / Login Items launches
mkdir -p ~/.config/xai && chmod 700 ~/.config/xai
printf '%s\n' "$XAI_API_KEY" > ~/.config/xai/api_key
chmod 600 ~/.config/xai/api_key
```

A subscription session always takes priority when it is present and unexpired, so installing an
API key does not change behaviour for people already signed in via `grok`.

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
- **Appearance** — "Show idle pill" (hide the resting dot entirely; the trigger key, menu-bar icon
  and the session bar while dictating all keep working) and "Reset panel position"
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
2. It reads what's already in that field and puts the caret after the last character.
3. It writes the text into the selection, joining with a space if needed.

Terminals, canvases and most web views expose no editable text to Accessibility. Those fall back
to a synthetic `⌘V` — but the caret is still moved to the end first where possible, and your
previous clipboard contents are snapshotted and restored afterwards. Either way, what you had
copied is still there when it's done.

## Privacy

- Your audio is streamed to xAI's speech-to-text service to be transcribed. Nothing goes anywhere
  else.
- Credentials are read fresh at the start of each recording: the Grok token from
  `~/.grok/auth.json`, or your API key from the environment / `~/.config/xai/api_key`. A valid
  subscription token is preferred when both are present. Quill never copies, stores or transmits
  credentials anywhere except to xAI.
- Your last 20 transcripts are kept locally so you can re-copy them. Clear them with
  `defaults delete com.freeze.quill history`.
- Quill does **not** log keystrokes. A debug trail exists for troubleshooting the trigger key and
  stays off unless you explicitly turn it on.
- `~/Library/Logs/Quill.log` records what it did — which app it wrote into, and whether the text
  landed.

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

`install-identity.sh` creates a local self-signed certificate so the app's code identity stays
stable between builds. That matters more than it sounds: with ad-hoc signing macOS treats every
rebuild as a brand-new app, silently drops your Accessibility and Microphone grants, and leaves
the old entries sitting in System Settings still looking enabled. The certificate lives in its own
keychain, so builds never prompt for your password.

Verify the transcription path without a microphone:

```sh
# 16 kHz mono PCM16: ffmpeg -i in.wav -ar 16000 -ac 1 -f s16le out.pcm
QUILL_SELFTEST=out.pcm ~/Applications/Quill.app/Contents/MacOS/Quill
```

## Known limits

- Settings live per-machine and don't sync.
- A recording stops itself after 5 minutes, or after 10 seconds if it hears nothing at all.
- If your Grok token has expired and `grok` isn't running to refresh it, Quill falls back to an
  API key when one is configured; otherwise it says so rather than failing quietly.
- STT over an API key is billed by xAI against that key. Subscription transcription is not.
- Not notarised — see above.

## Licence

MIT. Use it for anything.
