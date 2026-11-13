# Maintaining Closeup

This page is for whoever keeps Closeup working: how to check it, which parts break most easily, and what to do when a new macOS comes out. You don't need to be a full-time programmer to follow it.

## The one command

```bash
./check.sh
```

It builds the app, runs every test and prints a short summary ending in `RESULT: PASS` or `RESULT: FAIL`. It takes a minute or two. It needs Xcode, but no Apple ID and no permissions, and it never opens the app.

Run it:

- before and after any change to the code,
- after updating Xcode or macOS,
- before merging anything into `main` (the updater installs whatever is on `main`).

```bash
./check.sh --future
```

This also lists code that the newest macOS marks as outdated. See [When a new macOS ships](#when-a-new-macos-ships).

The full output of the last run is in `build/check/` (`build.log`, `test.log`).

## Reading a failure

| What you see | What it means | What to do |
|---|---|---|
| `FAIL The app doesn't build` | The code has an error. The lines under it name the file and line. | Fix that line, or undo the last change. |
| `NOTE n build warning(s)` | It works, but the compiler is uneasy. The build used to have none. | Worth fixing soon; new warnings often become errors in a later Xcode. |
| `FAIL n of m tests fail` | Something that used to work has changed. Each failing test is named, with what it expected. | Read the test's name and comment in `CloseupTests/`. Either the change broke something (fix the code) or you changed the behaviour on purpose (update the test). |
| `The exported frame at … no longer matches golden-….png` | The exported video looks different from the reference pictures. | See [The golden export test](#the-golden-export-test). |
| `FAIL The tests didn't run` | The tests don't compile, or one crashed. | Look at the lines under it, then `build/check/test.log`. |

## What the tests cover

All tests are in `CloseupTests/`. They run without a screen, camera or microphone, using made-up frames and sound.

| File | What it protects |
|---|---|
| `CursorLogTests` | Lining the cursor log up with the video; reading old `cursor.json` files |
| `CursorTrackTests` | Cursor smoothing, click "press", idle fade, cursor shapes |
| `ZoomTests` | Automatic zooms from clicks and typing; the camera's easing |
| `TimeEditTests` | Cuts and speed-ups, automatic edits, auto-trim, filler sounds |
| `ExportSettingsTests` | Export sizes and presets; reading old and damaged `style.json` files |
| `ProjectFilesTests` | Saving, loading and renaming a recording's folder; reading old `project.json` files |
| `VideoWriterTests` | The screen video file, including what happens when it fails |
| `MediaFileWriterTests` | Microphone files at every sample rate, from Bluetooth headsets to studio interfaces |
| `AudioTests` | Speech detection and audio clean-up |
| `RecoveryTests` | Rescuing a recording that was cut off by a crash |
| `EditorExportTests` | The editor and exporter together; one test per bug that was fixed |
| `GoldenExportTests` | That an export still looks right (see below) |

How the tests are built matters if you add files:

- The test target compiles the app's own source files directly, so it never has to launch the app. Any new file under `Closeup/` is picked up automatically.
- Three things are deliberately left out of the test target: `App/CloseupApp.swift` (the app's starting point), `Assets.xcassets` and `Closeup.entitlements`. If you ever add a second file with `@main`, exclude it the same way (in Xcode: select the file, then untick `CloseupTests` under Target Membership).
- `VideoWriter.breakForTesting()` exists only in the test build. It puts the file in the state a full disk would.

## The golden export test

`GoldenExportTests` exports a two-second sample recording with the default look and compares three frames with the reference pictures `CloseupTests/Fixtures/golden-*.png`. Small differences are allowed, because video compression isn't identical on every Mac.

If it fails and you did not mean to change how exports look, the change you just made broke something. The failure message gives the path of a picture showing what the export looks like now; open it next to the reference picture.

If you changed the look on purpose (new default padding, a different cursor, anything in `ExportStyle`'s defaults or `FrameCompositor`):

1. Delete `CloseupTests/Fixtures/golden-*.png`.
2. Run `./check.sh`. It fails once and saves new pictures.
3. Open the three new pictures and make sure they look the way you intended.
4. Run `./check.sh` again. It should pass. Commit the new pictures with your change.

If the test fails after a macOS or Xcode update with a difference just over the limit, Apple's video encoder has probably changed slightly. Look at the "now" picture; if it looks the same to your eye, follow the four steps above.

The sample recording itself is made by `scripts/make-fixture.swift`. You only need that if you want a different sample.

## The fragile parts

These are the places most likely to break, roughly in order.

### 1. Permissions

Nothing here can be tested automatically. After any change near it, do the [manual checklist](#manual-checklist).

- **Screen Recording** has no entitlement or Info.plist key. `ScreenRecordingPermission.swift` asks with `CGRequestScreenCaptureAccess` and checks with `CGPreflightScreenCaptureAccess`. macOS often reports the old answer until the app relaunches, which is why the permission screen has a Relaunch button. Recent macOS versions also re-ask the user every so often.
- **The permission belongs to the signed app, not the name.** Building with a different team or bundle ID makes macOS treat it as a new app and ask again. The updater's fallback (`app.closeup.Closeup.<team>`) does exactly that.
- **Camera and microphone** need both the entitlements in `Closeup.entitlements` and the usage texts in the build settings (`INFOPLIST_KEY_NS…UsageDescription`). Remove either and macOS kills the app the moment it touches the device.
- **The System Settings link** in `ScreenRecordingPermission.openSystemSettings()` is a hard-coded address that Apple has changed before. If the button stops opening the right page, that string is why.

### 2. Screen capture (ScreenCaptureKit)

Files: `Recording/ScreenRecorder.swift`, `CaptureTarget.swift`, `CaptureSources.swift`.

- Apple changes this framework every year. A stream that the system stops (window closed, user clicks Stop in the menu bar) arrives in `stream(_:didStopWithError:)`; stopping an already-stopped stream can hang, which is what `stoppedBySystem` guards.
- Only frames marked `.complete` are written (`isCompleteFrame`). If recordings come out empty after an update, check that first.
- Capture is at a fixed size chosen when recording starts. Resizing a window during a recording is not handled.

### 3. Writing the recording files

Files: `Recording/VideoWriter.swift`, `MediaFileWriter.swift`.

- `AVAssetWriter` does not report mistakes politely: calling it in the wrong state, or with settings the encoder can't do, crashes the app with an error Swift cannot catch. That is why the code checks `status == .writing` before finishing and `canApply(outputSettings:)` before creating an input. Keep those checks.
- Files are written in one-second pieces (`movieFragmentInterval`). That is what makes crash recovery possible; removing it brings back "a crash loses the whole recording".
- Audio settings depend on the microphone's sample rate (`MediaFileWriter.audioSettings`). The rules are in the comment there and are tested for every common rate.

### 4. Crash recovery

File: `Project/RecordingRecovery.swift`. While recording, the folder contains extra files:

| File | What it holds |
|---|---|
| `recording-in-progress.json` | What is being recorded |
| `cursor-in-progress.jsonl` | The cursor log so far |
| `cursor-shapes-in-progress.json` | Cursor shapes seen so far |
| `screen.mov.start`, `camera.mov.start`, … | When each file began |

A normal Stop removes them. If they are still there when Closeup next opens and there is no `project.json`, the recording was interrupted and is finished automatically. A folder that has them but no usable video is left alone and stays out of the sidebar; it can be deleted by hand in Finder.

### 5. The editor's settings flow

File: `UI/ProjectEditorModel.swift`, function `styleDidChange`. Every settings change passes through it, and several past bugs lived there (export using an older trim, Undo applying only part of a change). The rule: each kind of change is checked on its own and none of them returns early. `EditorExportTests` covers this.

### 6. Smaller things that depend on Apple not changing something

- **The global shortcut** (`GlobalHotKey.swift`) uses Carbon, a very old part of macOS. If ⌥⇧⌘R stops working after an update, start there. It also fails silently if another app owns the shortcut.
- **Hiding the main window while recording** (`AppState.hideMainWindow`) finds the window by an identifier that starts with `main`, which is how SwiftUI names it today.
- **Voice isolation** in `AudioCleaner.swift` finds Apple's audio effect by a four-letter code. If it isn't found, clean-up carries on without it.
- **Captions** use `SpeechAnalyzer` on macOS 26 and later, and the older `SFSpeechRecognizer` before that.
- **The cursor's shape** comes from `NSCursor.currentSystem`.

## Old recordings must keep opening

- `project.json` and `cursor.json` are read as-is. Adding a field that isn't optional makes every existing recording unreadable. Add new fields as optionals.
- `style.json` is read field by field with defaults (`ExportStyle.init(from:)`). A new setting needs a `decodeIfPresent` line there, like the others.
- A `style.json` that can't be read is copied to `style (unreadable).json` before defaults are used, so nothing is lost.
- `ProjectFilesTests`, `CursorLogTests` and `ExportSettingsTests` each contain a file exactly as version 1 wrote it. If one of those tests fails, old recordings have stopped opening.

## When a new macOS ships

1. Update macOS and Xcode, then run `./check.sh`. If it passes, the logic and the export pipeline still work.
2. Run `./check.sh --future`. It counts the uses of things Apple now marks as outdated.
   - As of macOS 27 there are 34, nearly all in recording and export (`AVAssetWriter`, `AVAssetReader`, the custom video compositor) plus a few in `AudioCleaner`. They still work.
   - A rising number is a warning, not an emergency. Apple usually keeps outdated things working for years.
   - They cannot simply be replaced while Closeup still supports macOS 14, because the replacements only exist on newer systems. When you raise the minimum macOS version (`MACOSX_DEPLOYMENT_TARGET`), these become ordinary build warnings and that is the time to replace them, one file at a time, running `./check.sh` after each.
3. Do the [manual checklist](#manual-checklist). Permissions and real capture are exactly what the tests can't see, and exactly what a new macOS tends to change.
4. If the golden export test fails by a small margin, see [The golden export test](#the-golden-export-test).

## Manual checklist

For the things no test can do. About ten minutes.

1. Delete Closeup from System Settings → Privacy & Security → Screen & System Audio Recording, open the app, and go through Request Access → System Settings → Relaunch. The picker with your displays should appear.
2. Record your display for 20 seconds with camera and microphone, moving and clicking the mouse. Press Stop. The editor should open, and the cursor, zooms, your face and your voice should line up.
3. Export at 1080p and play the file. It should look like the preview and sound in sync.
4. Record a single window, and close that window while recording. Closeup should stop by itself and save.
5. Start a recording, then press ⌘Q. Closeup should save the recording before it quits; reopen it and check the recording is in the sidebar and plays.
6. Start a recording and force-quit Closeup after ten seconds (⌥⌘Esc). Reopen it. It should say it recovered a recording, and that recording should play up to about the last second.
7. Record with Bluetooth headphones (AirPods) as the microphone. Your voice should be in the recording.
8. Unplug (or switch off) the chosen camera or microphone, then press Record. It should refuse with a message instead of recording without it.
9. Record for two minutes with Activity Monitor open. Closeup's memory should stay steady, not climb.

## Disk space

A recording's folder is almost entirely three kinds of file; the `.json` files are tiny.

| File | Decided by | Notes |
|---|---|---|
| `screen.mov` | `VideoWriter` (a ceiling of 0.1 bits per pixel per frame) | Small when little moves, large for video or scrolling. This is the original, so lowering it loses sharpness for good, most visibly when zoomed in. Left alone on purpose. |
| `Export ….mp4` | `ExportResolution.bitrate` in `VideoExporter.swift` | Safe to delete in Finder once posted: an export can always be made again from the editor. |
| `camera.mov` | `MediaFileWriter.cameraBitrate` | |

The export and camera numbers were halved once, after measuring on a real recording that the picture didn't visibly change. They change file size only; the 720p / 1080p / 4K choice sets the picture size and is separate.

## Housekeeping

- **Your Team ID must not be committed.** Xcode writes it into `Closeup.xcodeproj/project.pbxproj` when you pick a team. Before committing, check `git diff` for a `DEVELOPMENT_TEAM = …` line and leave it out.
- **No third-party packages.** Closeup uses only Apple's frameworks; there is nothing to update except Xcode.
- **Logs.** The recording pipeline logs what it does. To read the last ten minutes:

  ```bash
  log show --last 10m --predicate 'subsystem == "app.closeup.Closeup"'
  ```
- **The updater** (`Update Closeup.command`) downloads `main` from GitHub and builds it. Anything merged into `main` reaches everyone who presses Update, so run `./check.sh` first. Any new commit on `main`, even a text change, makes the app offer an update.
