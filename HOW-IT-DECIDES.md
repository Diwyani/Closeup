# How Closeup decides

The small decisions it makes for you, so the video looks edited without you editing it. Full details are in the [README](README.md#how-it-decides).

| | What it does | How it decides |
|---|---|---|
| 🎙️ | **Records clean, in sync** | Screen, camera, mic, system audio and cursor share one system clock, so voice and face never drift. |
| 🎙️ | **Camera ready on frame 1** | The camera starts during the 3-2-1 countdown, so exposure has settled before you're recording. |
| 🎙️ | **Never freezes your Mac** | Frames go straight to the hardware encoder. If memory ever passes 2 GB, it drops a frame instead of piling them up. |
| 🎙️ | **Leaves itself out** | The countdown, camera preview and Closeup's windows never appear in the video. |
| 🔍 | **Zooms before you click** | Starts 0.5 s early, so it's already in when the click lands, and holds 1.5 s after. |
| 🔍 | **No zoom ping-pong** | Actions under 3 s apart share one zoom, and zooms under 1 s apart join. It never pops out and straight back in. |
| 🔍 | **Calm camera** | Zoomed in, it only pans when the cursor leaves the middle 55% of the view, instead of chasing every wiggle. |
| 🔍 | **Watches your typing** | While typing, it looks at the field you last clicked (within 10 s), not where the mouse drifted. |
| 🔍 | **Ignores the stop shortcut** | Keystrokes in the last second don't trigger a zoom. |
| 🖱️ | **Smooth without lag** | The cursor path is blurred over up to 80 ms in both directions, so jitter goes but it never trails behind. |
| 🖱️ | **Real cursor shapes** | Checks the actual cursor (arrow, text beam, hand) every 0.1 s and redraws the same one, bigger. |
| 🖱️ | **Scales with zoom** | The cursor grows with the zoom, like the screen under it. Hidden when it leaves the recorded area. |
| 🖱️ | **Gets out of the way** | Fades after 1.5 s still. Motion blur only when it moves fast (up to 24 px). |
| 🗣️ | **Hears you talking** | Takes the quietest 10% of the mic as the room. Anything 12 dB louder is speech; gaps under 0.35 s are one sentence. |
| ✂️ | **Never cuts you off** | Speed-ups and cuts skip anything with your voice, a click, a keystroke or mouse movement. |
| ⏩ | **Fast-forwards waits, doesn't delete them** | Quiet waits of 3 s+ are sped up (4×), not cut, so you still see the page load. Voice pitch stays normal. |
| ✂️ | **Trims dead air** | Quiet pauses of 1.5 to 3 s are cut, keeping 0.3 s on each side so it doesn't feel jumpy. |
| ✂️ | **Finds the real start and end** | Auto-trim keeps 0.5 s before your first action or word to 1 s after your last, ignoring the reach for Stop. |
| ✋ | **Your edits win** | Move or delete any zoom, cut or speed-up and the automatic ones step aside. Reset brings them back. |
| 💬 | **Captions that read well** | New line after a 0.6 s pause, 3 s, 7 words or a sentence end. Never overlap. Made on your Mac. |
| 🎥 | **Camera that fits** | Cropped to fill any shape, never stretched. Side by side splits 64/36 in wide videos, 50/50 in tall ones. |
| 🎥 | **Smooth layout changes** | Bubble to full screen blends over 0.45 s, starting just before the change, so it lands on time. |
| 🎚️ | **Broadcast-level voice** | Noise removal, rumble cut below 80 Hz, room quieted between words, loudness to about −16 LUFS, peaks never clip. |
| 🎬 | **Never stutters** | Exports a steady 60 fps even where the screen didn't change, so zooms keep moving. |
| 🎬 | **Sharp text at any size** | High-quality downscaling, designed on a 1080p canvas, so 4K and vertical exports match the preview. |
| 🔒 | **Nothing is lost** | Your original files are never changed. Every edit is a small settings file you can undo. |
| 🔒 | **Private** | Notes *that* you typed, never which keys. Captions and cleanup run on your Mac; nothing is uploaded. |

[github.com/Diwyani/Closeup](https://github.com/Diwyani/Closeup)
