# Quill for Windows

Same product as the Mac app: tap a key, talk, the text lands where you point.
Uses your Grok subscription. Nothing is rebuilt or replaced on the Mac.

Version **0.8.3** — feature-matched to the current Mac release.

## Install

```powershell
irm https://raw.githubusercontent.com/xfreeze2/quill/main/windows/install.ps1 | iex
```

Installs to `%LOCALAPPDATA%\Quill` and adds a Start Menu shortcut. No admin.

Or unzip `Quill-windows-x64.zip` from
[Releases](https://github.com/xfreeze2/quill/releases) and run `Quill.exe`.

## Use it

Same gestures as on the Mac:

1. **Tap `Control`** — a panel appears in the corner and starts listening.
2. **Talk.** The transcript streams in live.
3. **Finish** by pausing, saying "that's it" / "that's all", clicking the
   destination, tapping Control again, or pressing Escape to throw it away.

"open Grok" as the *first* thing you say opens a new Windows Terminal (or
Ghostty, or Command Prompt) window and types `grok`. Mid-sentence it is left
alone.

## What you need

| | |
|---|---|
| **Windows 10 1809+ / Windows 11, 64-bit** | Self-contained — no .NET install |
| **A Grok subscription _or_ an xAI API key** | Reads `%USERPROFILE%\.grok\auth.json` |
| **Microphone access** | Windows Settings ▸ Privacy ▸ Microphone |

There is no Accessibility toggle on Windows. The trigger is a low-level
keyboard hook; typing uses UI Automation, then Ctrl+V with the clipboard
restored if the field will not take a direct write.

## Build from this Mac (cross-compile)

Does **not** quit, rebuild, or reinstall `~/Applications/Quill.app`.

```sh
cd windows
./build.sh
```

Produces `windows/dist/Quill-windows-x64.zip`. The `.exe` is a PE32 binary
and cannot run on macOS.

## Layout

```
windows/
  src/Quill.Core     portable logic (commands, STT, spacing, polish…)
  src/Quill.App      Avalonia HUD + Win32 hook / recorder / insert
  tests/Quill.Tests  runs on this Mac
```
