# Testing Mirada

## Automated

```bash
swift test
```

53 tests, about 6 seconds on an M2 Max. They need no camera and no network.

| Suite | What it pins |
|---|---|
| `SettingsTests`, `StatsTests`, `ExitCodeTests` | Settings round-trip and forward compatibility, nearest-rank p50/p95, sysexits codes |
| `UprightMappingTests` | All eight EXIF orientations map corners to corners; portrait phone video |
| `EyeCropTests`, `EyeContourTests` | Crop box and anchor map against the training notebook's math; resized pixels within one level of OpenCV; rotated frames sample upright; Vision point order; crops partly outside the frame are refused |
| `GazeGeometryTests`, `OneEuroTests`, `FaceGateTests` | Gaze angle against the reference Python formula; filter convergence, noise reduction, lag with beta; blink and look-away hysteresis; tiny faces |
| `GoldenModelTests` | CoreML + Swift sampler against the **original TensorFlow graph** on real eye crops: cpu backend worst error < 2e-5, Neural Engine worst error < 2/255 inside the composited region |
| `CompositorTests` | Alpha 0 is bit-exact; GPU warp matches the CPU warper within 1.5 levels; rotation; odd frame sizes |
| `PipelineTests`, `FaceTrackerTests` | No face, strength 0 and disabled pass the same buffer; only pixels inside the eye crops change; the fade ramps in; tracking between detections; idle throttling; reset detects at once |
| `FileProcessTests` | `mirada process` end to end: same frame count, size, rate and duration; audio bit-identical (SHA-256); `--no-audio`; rotation and HEVC; `--start/--end`; cancellation deletes the partial file; bad ranges |

Fixtures: `Tests/Fixtures/clip.mp4` (10 s, 720p, two people, one with glasses), `clip_rot90.mp4` (stored sideways, tagged to play upright) and `golden/` (eye crops plus TensorFlow outputs). Rebuild them with `tools/prepare_fixture.sh` and `tools/convert_flx.py golden`.

## Measurements

| What | How | Result (M2 Max, 2026-10-13) |
|---|---|---|
| Live latency per stage | `mirada run --simulate Tests/Fixtures/clip.mp4 --seconds 20 --stats` (real-time paced, publishing to OBS) | 29.8 fps; landmarks 8.4/20.3, model 1.4/2.0, compose 0.9/1.2, **total 9.6/21.8 ms** (p50/p95) |
| Landmark cost and jitter | `mirada debug landmarks <clip> [--smooth] [--redetect N]` | Vision 4.0/12.5 ms with detection every 6th frame (12.9/14.7 every frame); jitter 1.5 px raw, 0.5 px smoothed |
| Model | `mirada doctor` | Neural Engine 1.2 ms, CPU 2.9 ms per frame (both eyes) |
| File speed | `mirada process Tests/Fixtures/local/clip_1080p_30s.mp4 -o out.mp4` | **7.8x real time** at 1080p, 6.5x at 720p |
| Memory over 30 minutes | `mirada run --simulate Tests/Fixtures/clip.mp4 --seconds 1800 --json`, `memoryMB` in each 5 s line | See DECISIONS.md, step 10 |
| Virtual camera | `open -a Mirada --args --self-test-virtual-camera`, then check `log show --predicate 'subsystem == "com.jcantor.mirada"'` | OBS: 84/84 frames read back |

M1 numbers are still to be measured: run the first and last rows on an M1 and add them here.

## Manual checklist

Run the app (`tools/build_app.sh`, open `build/dd/Build/Products/Debug/Mirada.app`) and keep **split** on so before and after are side by side. Turn on the debug overlay (⌘D) when something looks off: it shows the face box, the six points per eye, the model crops, the correction arrow and why correction is on or paused. For each case, note pass or fail and the macOS and camera you used.

**Setup**
- [ ] First launch asks for camera access; denying it shows `#1 allow camera access` with a working **open camera settings** button
- [ ] `mirada doctor` is all `ok` except, at most, camera access and the virtual camera
- [ ] Calibrate (⌘K): the camera dot sits where your camera is; **measure focal length** at a measured 55 cm gives a plausible value (a FaceTime HD camera at 720p is usually 900–1100 px)

**Faces**
- [ ] **Looking at the screen**: eyes lift toward the camera, the status reads `// gaze locked` with the amber ring, and nothing flickers at rest
- [ ] **Glasses**: frames stay straight and unwarped; reflections don't smear across the lens
- [ ] **Blinks**: the eyelid closes naturally (correction fades out within about 2 frames, and back in over about 0.3 s); no frozen open eye mid-blink
- [ ] **Head turns**: past about 25° left or right (or up or down) the status reads `// looking away` and the eyes are untouched; turning back fades correction in again
- [ ] **Looking at the camera already**: little or no visible change
- [ ] **Low light** (one lamp, or dim the screen): correction may shimmer, but never jumps to a wrong place; if landmarks are lost it passes through
- [ ] **Two faces**: the larger face is corrected, the other is left alone; the correction doesn't jump between people when both are similar in size
- [ ] **No face** (step away): `// looking for you`, and the picture is untouched
- [ ] **Far away**: past about 2 m, `// come closer` and no correction
- [ ] **Strength**: 0% is identical to before; 100% at a laptop's usual 10–15° still looks like your eyes

**Window and overlay**
- [ ] The preview fills its card and is centred from the first frame (no black area until a click)
- [ ] The window resizes only proportionally, between about 92% and 150% of its normal size
- [ ] ⌘D overlay appears in the preview (unmirrored) and in a call app via the virtual camera; it stays after closing the window; ⌘0 brings the window back

**Controls**
- [ ] ⌘G toggles correction with a fade; ⌘1/⌘2 switch Live and File; ⌘B flips in flip mode; ⌘K opens calibration
- [ ] VoiceOver reads every control; the strength slider and the before/after divider respond to increment and decrement
- [ ] Reduce Motion (System Settings > Accessibility > Display): the lock animation becomes a plain fade
- [ ] Light and dark appearance both look right

**Virtual camera**
- [ ] With OBS Virtual Camera installed: the status reads `:obs cam: live`; Zoom, Meet (Chrome), Teams and FaceTime show the corrected video when "OBS Virtual Camera" is selected
- [ ] Quitting Mirada: the call app's video stops updating (OBS shows its own placeholder)
- [ ] Paid team only: install Mirada Camera, approve it in System Settings, see it in call apps, and see the resting card when Mirada is closed

**Files**
- [ ] Drop an iPhone portrait video: the output plays upright, with sound in sync
- [ ] Cancel midway: no partial file is left
- [ ] A photo: the corrected copy keeps its orientation
- [ ] An HDR (HLG) iPhone video: the CLI warns and the output looks right in QuickTime
