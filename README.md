<p align="center">
  <img src="Closeup/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Closeup app icon">
</p>

<h1 align="center">Closeup</h1>

<p align="center">A screen recorder for macOS that turns raw recordings into polished demo videos.<br>
Smooth auto zoom, a tidy cursor, your face, captions — no editing skills needed.</p>

<!-- Add your demo video or GIF here -->

## Features

| | |
|---|---|
| **Auto zoom** | Zooms in on clicks and typing and follows the cursor. Every zoom can be moved, resized or removed on the timeline. |
| **Cursor** | Smoothed movement, adjustable size, click glow, motion blur, hides when idle. |
| **Camera** | Live preview while recording. Circle, square, tall or wide bubble in any corner, plus full-screen and side-by-side layouts you can switch on the timeline. |
| **Audio** | Microphone and system audio. Optional voice cleanup: noise removal and even loudness (about −16 LUFS). |
| **Captions** | Generated on your Mac from your voice, with word timing. Edit the text before exporting. |
| **Timeline** | Trim, cuts, speed-ups, camera layouts and text titles. |
| **Smart edits** | Auto-trim dead time at the start and end, speed up long waits, cut short pauses. Never touches anything you're saying. |
| **Look** | Gradient or solid background, padding, rounded corners, shadow. |
| **Export** | MP4 (H.264 + AAC) at a steady 60 fps, 1080p or 4K, in 16:9, 9:16, 1:1 or 4:3. |

Everything runs on your Mac. No account, no uploads, no third-party code: it's built only on Apple's frameworks.

## Requirements

- macOS 14 or later (captions work best on macOS 26)
- Xcode 26 or later — free on the Mac App Store

## Run it

1. Download this repository: **Code → Download ZIP**, then unzip it. Or clone it:
   ```bash
   git clone https://github.com/Diwyani/Closeup.git
   ```
2. Open `Closeup.xcodeproj` in Xcode.
3. Select the **Closeup** target → **Signing & Capabilities** → choose your own **Team**. A free Apple ID works.
4. Press **⌘R** to build and run.

## Limitations

Closeup is an early personal project. Right now:

- **No download yet.** There's no ready-to-open app. You need a Mac with Xcode to build it yourself (the steps above take a few minutes). A signed, notarized download needs a paid Apple Developer account, which may come later.
- **Mac only.** It's built on macOS frameworks, so it won't run on Windows, Linux or iPad.
- **Captions** work best on macOS 26. On older versions they need Siri or Dictation turned on in System Settings.
- **Voice cleanup** uses Apple's voice isolation when your Mac has it, and falls back to simpler noise reduction otherwise.
- **Smart edits** use your mouse, keyboard and voice, not what's on screen. A silent wait where something important is loading may be sped up, so check the timeline before exporting.
- **Tested on one Mac** (Apple silicon, macOS 26). If something breaks on yours, please open an issue.

## Permissions

macOS asks for these the first time they're needed:

| Permission | Why |
|---|---|
| Screen & System Audio Recording | To record your screen and the sound your Mac plays |
| Camera | For the face bubble (only if you pick a camera) |
| Microphone | To record your voice (only if you pick a mic) |
| Speech Recognition | To make captions on older macOS versions |

After allowing Screen Recording, quit and reopen Closeup so macOS applies it.

## How to use

1. Pick a display or window, and optionally a camera and microphone.
2. Press **Record** (or **⌥⇧⌘R** from anywhere). A 3-2-1 countdown starts.
3. Stop from the menu bar icon or with **⌥⇧⌘R** again. The editor opens.
4. Adjust the look on the right and edit on the timeline at the bottom.
5. Click **Export MP4**. The file is saved in the recording's folder; **Show in Finder** takes you there.

Recordings are kept in `~/Movies/Closeup`, one folder per recording. Your original files are never changed: every edit is stored in a small `style.json` next to them.

## How it decides

| | Rule |
|---|---|
| **Zoom** | On each click or bout of typing. Starts 0.5 s early and holds 1.5 s after. Actions under 3 s apart share one zoom. Pans only when the cursor leaves the middle 55% of the view. |
| **Speed up** | Waits of 3 s or more with no input and no talking. 0.75 s of normal speed is kept on each side. |
| **Cut** | Pauses from 1.5 s (adjustable) with no input and no talking. 0.3 s is kept on each side. |
| **Trim** | From 0.5 s before the first click, keystroke or word to 1 s after the last. |

## Project structure

```
Closeup/
  App/         App entry point and app state
  Recording/   Screen, camera, mic and cursor capture
  Project/     The recording folder and its files
  Rendering/   Frame drawing, zoom, captions, layouts, audio cleanup
  Export/      MP4 export
  UI/          Recorder, editor, timeline and settings panel
```

## Contributing

Fork it, change it, make it yours. If you fix a bug or build something others would like, send a pull request and I'll review it.

- **Found a bug or have an idea?** [Open an issue](../../issues/new/choose).
- **Want to contribute code?** Read the [contributing guide](CONTRIBUTING.md) first. It covers forking, branches, the testing checklist and what I look for in a review.

## Credits

Designed and directed by Diwyani Vajpayee. Built with [Claude Code](https://claude.com/claude-code) (Claude Opus 5.5).

Inspired by tools like Screen Studio. Closeup is an independent project and is not affiliated with Screen Studio.

## License

[MIT](LICENSE)
