# How Closeup decides

Everything it does automatically, at a glance. Full details are in the [README](README.md#how-it-decides).

| | What | Rule |
|---|---|---|
| 🔍 | **Zoom in** | On every click and while typing. Starts 0.5 s early, holds 1.5 s after. |
| 🔍 | **One zoom or two** | Actions under 3 s apart share one zoom. Zooms under 1 s apart join. |
| 🔍 | **How close** | 2× by default, adjustable per zoom (1.25 to 3.5×). |
| 🔍 | **Follow** | Pans only when the cursor leaves the middle 55% of the view. Never shows past the screen edge. |
| 🔍 | **Typing** | Looks at where you're typing (your last click), not where the mouse wandered. |
| 🔍 | **Motion** | Spring motion, 120 steps a second, no overshoot. |
| 🖱️ | **Smooth cursor** | Blurred over up to 80 ms both ways: no jitter, no lag. |
| 🖱️ | **Idle cursor** | Fades out after 1.5 s still. |
| 🖱️ | **Clicks** | Cursor presses 20%, with a glow that fades over 0.45 s. |
| 🖱️ | **Motion blur** | Grows with speed, up to 24 px. |
| 🗣️ | **Speech** | Anything 12 dB above the room's quietest 10%. Gaps under 0.35 s count as one sentence. |
| ⏩ | **Speed up** | Quiet waits of 3 s+ (no input, no talking). 4×, voice pitch kept, 0.75 s normal speed on each side. |
| ✂️ | **Cut** | Quiet pauses of 1.5 to 3 s. Leaves 0.3 s on each side. |
| ✂️ | **Never cut** | Anything with your voice, a click, a keystroke or mouse movement. |
| ✂️ | **Auto-trim** | From 0.5 s before your first action or word to 1 s after your last. Ignores the reach for Stop. |
| 💬 | **Captions** | On-device. New line after a 0.6 s pause, 3 s, 7 words, or a sentence end. |
| 🎥 | **Camera** | Bubble at 24% of the short side, cropped to fill, mirrored. Layouts blend over 0.45 s. |
| 🎚️ | **Voice cleanup** | Noise removal, rumble cut below 80 Hz, loudness to about −16 LUFS, peaks never clip. |
| 🎬 | **Export** | Steady 60 fps, H.264, 20 Mbps at 1080p or 60 Mbps at 4K, Rec. 709 colour. |
| 🔒 | **Privacy** | Notes *that* you typed, never which keys. Nothing leaves your Mac. |

[github.com/Diwyani/Closeup](https://github.com/Diwyani/Closeup)
