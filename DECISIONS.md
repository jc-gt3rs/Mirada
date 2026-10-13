# Decisions

Each entry says what was decided, the evidence, and the date. Measured numbers come from JC's M2 Max (macOS 27.0.1, Xcode 27.0) unless noted.

## Reference research (2026-10-13)

### Where the reference code actually lives

The brief names `tf_models/flx.py` and `tf_models/transformation.py`. In WangWilly/gaze-correction-cam those files are now `tf_models/gaze_corrector_v1/{gaze_warp_model,spatial_transform,layers}.py`. The original research code is upstream at `chihfanhsu/gaze_correction` (`gaze_correction_system/flx.py`, `transformation.py`, `tf_utils.py`, `regz_socket_MP_FD.py`), from Hsu, Wang, Lei, Chen, "Look at Me! Correcting Eye Gaze in Live Video Communication", ACM TOMM 15(2), 2019.

### FLX weights license: bundle them, with notice

- Upstream commits the checkpoints in-repo (`gaze_correction_system/weights/warping_model/flx/12/{L,R}`) next to a BSD-3-Clause `LICENSES` file, "Copyright 2019 Chih-Fan Hsu". GitHub's license detector misses it only because of the file name.
- WangWilly's repo is BSD-3 (same copyright line) and its v0.1.1 release `weights.zip` contains the same checkpoints. `tools/fetch_upstream.sh` verifies they are byte-identical by SHA-256.
- BSD-3 allows binary redistribution if the copyright notice, conditions and disclaimer ship with it. They are in `THIRD_PARTY_NOTICES.md`, and the app shows them.
- Caveat: the weights were trained on the DIRL gaze dataset (37 volunteers). The dataset's own terms are not published. JC chose to bundle anyway, with this caveat stated in the notices.
- Decision: bundle the converted weights. No first-run download. (JC, 2026-10-13.)

### The reference "virtual camera" is not in the source

- The README's virtual camera ships only in a closed, prebuilt `GazeAt-Installer.dmg` (330 MB) on the Releases page. There is no CoreMediaIO code on `master`.
- PR #5, "Add macOS Virtual Camera (CoreMediaIO DAL Plugin)", was Copilot-generated and closed unmerged. Full correction in it relied on IPC to the Python backend. PR #6 (open) adds a Python v3 estimator.
- Decision: Mirada writes its own CMIO Camera Extension. Nothing is reused.

### Bugs in the reference that Mirada does not copy

| Reference behaviour | Training behaviour | Mirada |
|---|---|---|
| Feeds eye crops to the model in **BGR** (OpenCV frame) | Training data converted with `cv2.COLOR_BGR2RGB`, so the model learned **RGB** | RGB |
| Crop bounds truncated with `int()` | Crop bounds rounded (`int(v + 0.5)`), anchors rounded, top-left truncated | Training math, exactly |
| Gaze angle cast to `int` (1° steps, visible jumps) | Float labels in 10° steps | Float, smoothed |
| Hard paste with a 3/4 px border cut | n/a | Feathered blend inside the same border |

### Model facts the port has to match

- Inputs: RGB 48x64 in [0,1]; anchor map with 12 channels; angle `[vertical, horizontal]` in degrees. Training covered ±40° horizontal and ±30° vertical with frontal head pose only ("Trained head poses: 0").
- Anchor points per eye, in order: outer corner, upper-outer, upper-inner, inner corner, lower-inner, lower-outer. Training labels contain a 7th point (pupil), dropped by `ef_dim = 12`. Each point contributes `(col − x, row − y)` in crop pixels.
- "L" weights correct the subject's **left** eye, which is on the image's right in an unmirrored frame. "R" corrects the subject's right eye.
- Blocks are conv → ReLU → BatchNorm (inference statistics). Coarse level at half resolution, nearest upsample, 2x2 average smoothing; fine level outputs 2 flow + 2 light channels; flow through `tanh`; light weights through softmax over 2 channels.
- Sampler: pixel = 0.5·(x+1)·W with a `linspace(-1,1,W)` base grid. Corner indices are clamped *before* the weights are computed, so samples falling outside [0, W−1] get zero weight (black), and identity flow is a slight stretch. The port must reproduce this, because the weights were trained against it.

### Signing: free Personal Team cannot activate a system extension

- The maintainer's only team was a free Personal Team. A probe app with an embedded camera extension and `com.apple.developer.system-extension.install` fails provisioning with: *"Personal development teams … do not support the System Extension capability."* Without that entitlement, the same app and extension build and sign fine, app group included.
- Decision (JC): build Mirada's own extension (activates once `MIRADA_PAID_TEAM = YES` and a paid team ID are set) **and** an OBS bridge that feeds the already-installed OBS Virtual Camera (32.0.4, activated). Spike the bridge before relying on it.

### Build structure

SwiftPM package for `MiradaKit`, the `mirada` CLI and tests. XcodeGen `project.yml` for the app and the camera extension, because SwiftPM can't produce a signed `.app` with an embedded system extension. (JC, approach A.)

### Test footage

JC allowed third-party footage instead of a self-recorded clip. Sources must have a license that allows redistribution. Approved: "Video Blog- CBP Super Bowl LII Countdown to Kickoff - Day 1" (U.S. CBP, public domain) and, as a backup, "Was ist ein Vlog" (CC BY-SA 3.0). The CBP clip had everything needed (two people, glasses, frontal stretches, head turns, blinks), so the backup was never downloaded.

## Measured

Filled in by the steps that measure them.

### Landmarks: Apple Vision, no MediaPipe (step 3, 2026-10-13)

- Requests: `VNDetectFaceRectanglesRequest` revision 3 (continuous yaw, pitch, roll; revision 2's yaw is quantized to 0) feeding `VNDetectFaceLandmarksRequest` revision 3 with the 76-point constellation.
- With that constellation Vision returns **six points per eye in exactly the training order** (outer, upper-outer, upper-inner, inner, lower-inner, lower-outer). `EyePoints.fromContour` still re-derives the order from geometry, so a future Vision change can't silently scramble the anchors.
- Vision's `leftEye` is the eye on the image's left, i.e. the subject's right eye, which goes to the "R" model.
- Measured with `mirada debug landmarks` (release build, frontal frames only, |yaw| < 25°):

  | Clip | Vision p50 / p95 | Raw jitter (RMS 2nd difference) |
  |---|---|---|
  | `clip.mp4` 1280x720, 195 frontal frames | 11.4 / 12.3 ms | 1.53 px = 5.5% of a 27.9 px eye |
  | 1080p 30 s, 242 frontal frames | 12.5 / 14.3 ms | 1.87 px = 4.5% of a 41.6 px eye |
  | `clip_rot90.mp4` 640x360 rotated | 9.8 / 12.2 ms | 1.11 px = 7.8% of a 14.2 px eye |

  The jitter figure includes real motion (the speakers talk and gesture), so it is an upper bound on detector noise.
- Two similar-sized faces made plain "largest face" flip between people from frame to frame (jitter read 210 px before the fix). The tracker now follows the previous face (IoU > 0.3) unless another face is 1.3x larger.
- MediaPipe: not adopted. It has no supported macOS Swift package (bundling the TFLite runtime would be new scope), and Vision's noise is handled by the One Euro filter (step 5). Revisit only if filtered jitter is still visible.

### Model runtime: CoreML, fp16 network on the Neural Engine, fp32 warp (step 4, 2026-10-13)

Reference: the **original upstream training graph** (`L.meta`/`R.meta`, two-tower), restored from the checkpoints under TF 2.21 with `phase_train=False`, run on real eye crops Mirada extracted from the fixture clip (`Tests/Fixtures/golden`, two people, four angles from (0, 0) to (−25°, 30°)).

Both candidates were ported and checked against it. Latency is for **both eyes per frame**, 300–500 runs after warm-up, M2 Max:

| Candidate | Parity vs TF (worst abs) | p50 | p95 |
|---|---|---|---|
| CoreML fp32, CPU | 8.9e-6 | 2.42 ms | 2.57 ms |
| CoreML fp32, GPU | — | 4.41 ms | 5.41 ms |
| CoreML fp16, Neural Engine | see below | **0.40 ms** | 0.61 ms |
| CoreML fp16, CPU | 0.81 (mean 4e-3) | 1.34 ms | 1.51 ms |
| MLX (0.32.3) GPU, `mx.compile` | 4.7e-6 | 3.22 ms | 4.18 ms |
| MLX CPU | — | 19.2 ms | 20.0 ms |

MLX was measured through its Python package, because building mlx-swift needs Apple's separate Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`), which isn't installed here. That build requirement is itself a packaging cost. Python adds a little per-call overhead, but not the 8x gap to the Neural Engine.

**Decision: CoreML. MLX is dropped and none of its code is kept.**

fp16 broke parity only in the sampler: the 0–64 px sampling coordinates quantize to 1/16 px in half precision, and the in-bounds mask flips at the crop edge. So the shipped model stops at the flow and light weights. The warp and light correction run in float32, in Swift (`EyeWarper`, the reference) and in the Metal compositor. That also lets the compositor warp the full-resolution frame instead of a 64x48 crop.

Shipped models (`Sources/MiradaKit/Resources`, built by `tools/convert_flx.py coreml`):

| Model | Backend flag | Parity vs TF: whole crop | Inside the composited region (3 px rows / 4 px cols trimmed) | Mean |
|---|---|---|---|---|
| `FLXFlow16` fp16 | `--backend ane` (default) | 0.77 (edge mask flips) | **1.42/255** | 4.4e-4 |
| `FLXFlow32` fp32 | `--backend cpu` | 8.9e-6 | 8.9e-6 | 1.8e-7 |

Tolerances enforced by `GoldenModelTests`: cpu worst < 2e-5; ane worst inside the composited region < 2/255 and mean < 1e-3.

The brief's `--backend mlx|coreml` flag becomes `--backend ane|cpu`: there is one runtime, and the flag picks where it runs.

### Golden samples

The first "plain" sample had a bad landmark: the speaker was turned about 3/4 away and Vision put his far eye on the bridge of his nose. It was replaced with a frontal frame. That case is what the yaw fade (step 5) exists for.

### Smoothing, fades and the compositor (step 5, 2026-10-13)

**Landmarks.** A One Euro filter on every eye coordinate, in units of interocular distance, so one setting works at any face size and resolution. Sweep with `mirada debug landmarks --smooth` (RMS second difference, frontal frames):

| min cutoff / beta | `clip.mp4` 720p | single-speaker 1080p |
|---|---|---|
| raw | 1.53 px | 2.08 px |
| **1.2 Hz / 0.6 (chosen)** | **0.53 px** | **0.95 px** |
| 0.8 / 0.6 | 0.53 | 0.90 |
| 2.0 / 0.6 | 0.56 | 1.05 |
| 1.2 / 2.0 | 0.61 | 1.21 |

That is a 2.2–2.9x reduction. Lower cutoffs gain almost nothing and add lag.

**Fade.** A One Euro filter with beta 0 on the correction weight: 2 Hz going in (about 0.3 s, no pop when a face appears), 6 Hz going out (down to 0.2 in about 2 frames, ahead of a closing lid). Beta > 0 was wrong here: a 0→1 step reads as fast motion and the filter jumps (measured 0.96 on the first frame).

**Gates.** Correction fades to zero for: eye aspect ratio < 0.17 (re-opens above 0.21); |yaw| or |pitch| > 25° (back below 20°); interocular distance < 24 px. The look-away gate is what stops the failure seen in golden sampling, where a 3/4-turned face had its far eye on the nose.

**Compositor.** The model's flow lives on the 64x48 crop but is applied to the full-resolution frame, sampling the original image where TF would have sampled the crop. Eyes keep native detail. The outer 3 model pixels stay original (the training loss ignored them) and blend in over the next 6 (horizontal) or 5 (vertical). A GPU-vs-CPU test at model resolution agrees within 1.5 levels.

**Default camera position.** The reference's (0, −21, −1) cm suits a large monitor. At a typical 34 cm it implies a 31.6° correction, beyond the ±30° training range. On a Mac with a built-in display, Mirada derives the offset from the panel's physical height (camera 0.8 cm above the picture). See the calibration step.

### File mode (step 6, 2026-10-13)

- Video and audio are written by two concurrent tasks that each wait on their own writer input, so AVAssetWriter interleaves them without the classic all-video-then-audio deadlock.
- Audio uses `outputSettings: nil` on both ends: verified bit-identical (same packet count, same SHA-256 of the payload; ffmpeg MD5 matches too).
- Frames keep their source timestamps, so variable frame rate survives. The track keeps `preferredTransform`. Color tags are copied when the source has all three (primaries, transfer, matrix). HDR sources are processed at 8 bits with their tags kept, and the CLI warns.
- Default codec matches the source (H.264 or HEVC). Default bitrate matches the source, never below 0.08 bits per pixel.
- Speed, release build, M2 Max, Neural Engine backend: 720p 10 s at **3.7x** real time; 1080p 30 s at **3.8x** real time. The brief asks for faster than real time at 1080p.

### Virtual camera: own extension + OBS bridge (step 8, 2026-10-13)

- OBS Virtual Camera 32.0.4 exposes a source stream and a **sink stream** (CMIO direction 0), both 1920x1080 BGRA. Any CMIO client can open the sink with `CMIOStreamCopyBufferQueue` + `CMIODeviceStartStream` and enqueue sample buffers. That's how the OBS app itself feeds it.
- Loopback, run inside Mirada.app (`--self-test-virtual-camera`, which needs the app's camera permission): **87 magenta frames sent, 84 read back through "OBS Virtual Camera" as an ordinary camera, 84 of 84 matching**. Video-call apps see Mirada's output with no paid team and without OBS running. Caveat: don't run OBS's own virtual camera at the same time.
- Processes launched from a shell without camera permission get zero frames from any camera (status `notDetermined`). That is TCC, not a bridge failure.
- `CMIOSinkClient` scales frames to the sink's declared size with VideoToolbox (letterbox) and drops frames, rather than blocking, when the sink queue is full.
- Mirada Camera (`com.jcantor.mirada.camera`) is a CMIO extension with a 1280x720 30 fps BGRA source stream, a matching sink, and an engraved "camera is resting" card after 0.5 s without input. It builds, embeds and signs with the free team (sandbox + app group `<TEAM>.com.jcantor.mirada`, Mach service `<TEAM>.com.jcantor.mirada.camera`). **Not activated or run here**: activation needs a paid team (`MIRADA_PAID_TEAM = YES` switches the app to the entitled entitlements file).
- Target choice: Mirada Camera when its device exists, else OBS. Live output is never mirrored (call apps mirror the self-view themselves).
- `mirada run --simulate clip.mp4` (real-time looped file as the camera) published to OBS at 29.7 fps: total 16.4 ms p50 / 20.1 ms p95, 54 MB resident.

### Visual language (step 9, 2026-10-13)

Hermes Agent site, as seen in the browser (not just its text): a full-bleed saturated blue canvas, tall condensed light headlines, small letter-spaced uppercase labels, colon-wrapped tab labels (`:macOS:`), `#1 CONNECT` feature tags, `// MOST POPULAR` microcopy, white buttons with blue text, and a dense radiating-line engraving.

What Mirada takes, translated rather than copied:

- **Colour.** JC asked for no Hermes blue. The signature colour is a moss green sampled from his reference image of metallic olive paint: median #698129 (25th–75th percentile #607723–#77912F). Text and controls use #4F6420 on paper (5.8:1 contrast; the raw green only reaches 3.9:1) and #9DBA45 on night (8.9:1). The header band is #698129 (#55691F in dark mode) with a procedural flake texture echoing the reference's glitter. Paper #F4F0E6, ink #0E1028, night #090B1F. Amber #FF9E3D appears only for "gaze locked".
- **Layout.** Paper below a band, one bordered card with a soft shadow, rather than a blue canvas.
- **Type.** SF Pro condensed light for the wordmark, SF Mono for tags and microcopy (system fonts, licensed for app bundles).
- **Voice.** `#1 strength`, `:live:` / `:file:`, `// gaze locked`.
- **Art.** An original engraved eye in a ticked mirror medallion (`MiradaArt`), shared by the icon, the empty states and the camera's resting card. No Nous or Hermes artwork or names.
- **Controls are drawn in SwiftUI** (slider, chips, toggles) with accessibility values and adjustable actions. They match the look, and they render in `ImageRenderer`, which is how the README screenshots are made (this session can't capture the screen).

### Performance pass (step 10, 2026-10-13)

- **Vision was the bottleneck** (about 13 ms of a 16 ms frame). Face detection (rectangles, needed for the box and for yaw and pitch) costs about three times as much as landmarks. It now runs every 6th frame; in between, the last box moves with the eyes and only landmarks run, and a landmark confidence below 0.5 forces a fresh detection. Measured with `mirada debug landmarks --redetect N`:

  | Detection every | Vision p50 / p95 | Jitter (raw) |
  |---|---|---|
  | 1 frame | 12.9 / 14.7 ms | 1.53 px |
  | 3 frames | 4.3 / 13.0 ms | 1.48 px |
  | **6 frames** | **4.0 / 12.5 ms** | 1.50 px |
  | 10 frames | 3.7 / 10.3 ms | 1.44 px |

  Six keeps the yaw used by the look-away gate at most 0.2 s stale. With nobody in view, detection runs every 3rd frame (idle power; at most 0.1 s to pick someone up).
- Live, `mirada run --simulate clip.mp4 --stats`, publishing to OBS: 29.8 fps; landmarks 8.4/20.3, model 1.4/2.0, compose 0.9/1.2, **total 9.6/21.8 ms** p50/p95 (was 16.4/20.1). The p95 is set by detection frames and stays well inside 33 ms.
- File: 1080p **7.8x** real time (was 3.8x), 720p 6.5x.
- Not measured: an M1-class Mac (none available here). With the M2 Max p95 at 22 ms, M1 has roughly 1.5x headroom; confirm with TESTING.md.
- Fixed along the way:
  - `mirada run --preview` stalled once AppKit's run loop held the main actor. It now pumps events itself and updates the layer through the main dispatch queue.
  - `--seconds` was only checked every 5 s; it now has its own timer.
  - CLI and app now share the display-derived first-run camera position. The CLI had fallen back to the reference's 21 cm and over-corrected on a laptop.
  - A camera disconnect or session error now ends the stream with "camera unavailable" instead of freezing the picture.
- Memory, 30-minute soak (`mirada run --simulate clip.mp4 --seconds 1800 --json`, publishing to OBS): 53,978 frames at 29.96 fps, **0 dropped**. Memory peaked at 67.9 MB while warming up, then stayed flat at about 53 MB (52.1–54.8 MB from minute 10 to the end): no leak.
- **Open issue:** on live FaceTime-camera frames inside the app, Vision is about 2.5x slower than on file frames (face boxes 26–28 ms, landmarks 18–19 ms; total 25–29 ms p50). Running the camera alone, with its frames discarded, slows Vision on file frames about 1.5x, so the capture pipeline competes for the same accelerators. Not the cause: system camera effects (none on), colour tags (stripping them changed nothing), detection frequency (it's every 6th frame as designed). Pinning Vision to CPU or GPU trades landmark time for face-box and model time. Follow-up (offline, the same frames): Vision costs the same on BGRA, 420v and half-resolution input (face boxes 9–10 ms, landmarks about 3 ms), so input format isn't the cause; a dedicated user-interactive queue for Vision didn't help either. The gap between a back-to-back benchmark (landmarks 3 ms) and any frame-paced run (`mirada run --simulate`, the app; 7–12 ms) points to the Neural Engine and GPU clocking down in the gaps between 33 ms frames, with the camera adding its own load on top. This costs latency, not throughput: live in the app, 300 frames still arrive every 10 s. Next: measure dropped frames on a real face (count capture callbacks against processed frames), and if p95 crosses 33 ms, pipeline Vision for frame N+1 alongside the model and compose for frame N.
- **Live drops, measured with a real face (2026-10-13).** Before: 36 of 637 frames dropped (5.6%). Every 6th frame paid face boxes (28 ms) plus landmarks (19 ms), 47 ms against a 33 ms budget. The periodic face-box pass now runs on its own background queue, and the result is adopted on the next frame, so each frame only waits for landmarks. After: **5 of 905 dropped (0.55%)**, total 21.5 ms p50. Jitter is unchanged (1.46 px).

### Follow where you look (2026-10-13, after JC's live report)

JC looked at the left side of his screen, and Mirada left his eyes pointing left. The geometry (and the reference) assumed the user always looks at the screen centre, so only the vertical centre-to-camera offset was corrected.

- **Do Vision's pupils follow the iris?** Yes. In `mirada debug gaze` on the fixture clip, the average pupil offset between the corners moves about −0.10 of an eye width during a sideways glance with the head still, and +0.2 to +0.29 when the speakers turn toward each other. Each eye has a mirror-image bias that cancels when both are averaged.
- **Which sign does the model use?** On the golden crops, +horizontal moves the iris toward the image's right and +vertical moves it up, for both eyes.
- **Gaze** = smoothed head yaw + asin(gain × pupil offset). It is measured against a 30 s running median (the "usual direction", which absorbs personal and detector bias). The correction becomes centre-to-camera minus that deviation. Head pitch is left out: Vision's pitch jumps by ±6°.
- **Focal length:** unless measured, it is derived from eye spacing at an assumed 55 cm. The reference's 650 px made the centre-to-camera angle about 22° for JC; it is now about 12°.
- **Gains, from JC's live runs** (FaceTime camera; looking at middle, left, camera, right, middle for about 8 s each):

  | Run | Middle V / H | Left H | Camera V / H | Right H |
  |---|---|---|---|---|
  | gains 2.5/2.5, f = 650 | 22–26 / ~0 | −10 to −12 | **~18** / ~0 | +10 to +15 |
  | gains 4.0/7.5, focal from eye spacing | 11–14 / ~0 | −13 to −24 | **−3 to +3** / 0–6 | +16 to +25 |

  Vertical needs a much larger gain because the lids move with the eye and hide most of its vertical travel. The **2. camera** calibration step learns each person's vertical gain.
- ~~The "looking away" gate on gaze was raised from 25° to 30°.~~ Removed: with his eyes turned toward the corners, JC got "looking away" and no correction, which is not what he wants. Two causes. The gate itself (the brief only asks to pause on head turns and blinks). And the arcsine, which blew up near the corners (with gain 4, an offset of 0.25 read as 90°). The eye angle is now linear in the offset (gain × offset, radians) and capped at ±45°; corrections are clamped to the model's training range (±40° sideways, ±30° vertical). Expect iris distortion at those extremes.
- **The "middle" drifted.** It was the median of the last 30 s of gaze, and during the tests JC spent long stretches looking at the camera and the sides. Looking back at the screen then read as looking away, and the correction overshot (JC: "sometimes it gets lost"). Now **1. middle** stores the eyes' reading (pupil offset and head yaw, median of the last 0.5 s) in settings, and it stays fixed across launches. Until calibrated, the middle is learned over 90 s instead of 30. Pupil readings beyond 0.35 of an eye width sideways (or 0.3 vertically) are treated as Vision losing the pupil and ignored. The tracker now keeps raw readings and applies the gains at the end, which also fixed the camera-calibration helper ignoring head yaw.

### Other apps and the closed window (2026-10-13)

JC reported that Photo Booth and other camera apps showed no correction, even with Mirada open.

- **Frames do reach other apps.** A second Mirada process (`--probe-virtual-camera`, which reads like any app and publishes nothing) read OBS Virtual Camera at 30 fps while Mirada was live. Mean brightness was 111.8–112.0, matching the FaceTime camera's 111.9–112.4 at the same moment, so it was the live video, not a placeholder. The likely misses: the app has to select "OBS Virtual Camera" (macOS gives apps no way to alter another camera's feed), and closing the window could end Mirada. A SwiftUI app whose only scene is a `Window` may quit when that window closes.
- **Fixes.** An app delegate returns false from `applicationShouldTerminateAfterLastWindowClosed`, reopens the window from the Dock, and holds a latency-critical activity so App Nap can't throttle live processing with no window on screen. Verified with `--close-window-after 3`: correction (and publishing) continued after the window closed.
- **Distance by hand.** Calibration #2 takes the camera-to-eyes distance in cm, from a tape, ruler, or a count of hand spans (about 20 cm, adjustable), and derives the focal length from the current eye spacing.

### Focal length from the camera, tracking recovery, window scaling (2026-10-13)

- **Automatic distance, no hand needed.** JC asked for automatic distance calibration from a hand seen by the camera. A hand of assumed size at an unknown distance, through a lens of unknown focal length, gives the same single equation the eye spacing already gives, so it can't resolve distance on its own. Instead: the FaceTime camera attaches `MetadataDictionary` to every frame with `FocalLenIn35mmFilm = 27.7 mm` (and `FocalLength = 1.27 mm`, sensor 1920x1080). Converted by the 35 mm frame's diagonal, that is **941 px at 1280x720**; the reference's default was 650. Mirada now uses it automatically. The 55 cm assumption is only the fallback for sources without lens metadata (most files), and a measured value still wins. The hand-span and typed-distance UI was reverted to the earlier slider + "measure" card, which now shows the automatic value and distance, with a way back to automatic.
- **"Sometimes it gets lost" (second cause).** The logs showed `Cropping failed. Specified ROI is outside of input image bounds` on every frame once the carried face box drifted past the frame edge: the tracker kept reusing the bad box. The carried box is now clipped to the image (dropped if too small), and any failure of the tracking pass falls back to a fresh detection instead of failing the frame.
- **Window.** ~~The UI was scaled uniformly with the window.~~ JC wanted only larger, constant text, and the scaled layout left a white strip under the content. Now the width is the only free dimension (380–640 pt). Text stays its size; the preview keeps one ratio (348:280) at every width (measured 348x280, 500x402.5, 565x454.5); the window's height follows the content, and the paper background reaches the window's edges. Type is larger: tags 12 pt, values 13 pt, notes 11–12 pt (was about 10).
- **Name in other apps.** It stays "OBS Virtual Camera" on a free team: the device name belongs to OBS's extension. "Mirada Camera" needs the paid-team build.

