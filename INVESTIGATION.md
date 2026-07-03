# Multi-Layer Anonymizer — Investigation & Status

## Issues Fixed This Session

### 1. DC Bias / Image Bounce with Temporal Jitter
**Problem:** Value noise has a non-zero spatial mean over any finite domain. `(noise * 2 - 1) * amount`
has a seed-dependent mean → whole image translates by a random amount per frame →
image bounces when temporal jitter changes the seed every frame.

**Wrong fix (center-point anchoring):** Subtracting the noise value at the frame center only zeroes
displacement at that one pixel; the whole-frame mean displacement equals `−(noise_center * 2 − 1) * amount`,
which is still random per seed.

**Correct fix (sparse grid mean):** Sample noise on a ~64×64 uniform sparse grid, compute the mean,
subtract it from every pixel's displacement. Mean displacement ≈ 0 for any seed, frame size, or orientation.
Applied to: `shared/AnonymizerAlgo.h` (CPU), `src/Anonymizer_GPU.mm` (Premiere GPU), `ofx/AnonymizerOFXMetal.mm` (Resolve GPU).

### 2. OFX Struct Layout Mismatch
**Problem:** `AnonParamsHost` in `ofx/AnonymizerOFXMetal.mm` was missing `mDistortBiasDx` / `mDistortBiasDy`
fields that the Metal kernel's `AnonParams` struct had. The kernel read garbage values for the bias fields.

**Fix:** Added the two float fields to the OFX `AnonParamsHost` struct, added `#include "AnonymizerAlgo.h"`,
and added the sparse-grid mean computation to the OFX render path.

### 3. Version Number — Single Source of Truth
**Problem:** `MAJOR_VERSION`, `MINOR_VERSION`, `BUG_VERSION` were hardcoded in `src/Anonymizer.h`
and had to be changed in two places.

**Fix:** `CMakeLists.txt` now uses `project(PremiereAnonymizer VERSION x.y.z)` as the single source of truth.
`PROJECT_VERSION_MAJOR/MINOR/PATCH` are injected as compile definitions. `src/Anonymizer.h` no longer
defines the version macros — they come from CMake only. Current version: **1.4.7**.

---

## Ongoing Issue: Image Shifts in Premiere for Mismatched Aspect Ratio

### Symptom
When a clip's aspect ratio does not match the sequence's aspect ratio in Premiere Pro,
applying the effect causes the image to shift:

| Clip AR | Sequence AR | Shift |
|---------|-------------|-------|
| 16:9 (landscape) | 9:16 (portrait) | up-right |
| 9:16 (portrait) | 16:9 (landscape) | down-left |
| 16:9 | 16:9 (matched) | none |
| 9:16 | 9:16 (matched) | none |

FCP and DaVinci Resolve are unaffected. Issue is Premiere-specific.

### Diagnostic Process

**Step 1 — Added NSLog to `src/Anonymizer_GPU.mm`**

Logged `bounds`, `w`, `h`, `srcPitch`, `distortAmount`, `distortScale`, `biasDx`, `biasDy`, `samples`
on every GPU render call. Findings from Console.app:

- Frame dimensions look correct (1920×1080 for landscape sequences, 1080×1920 for portrait sequences)
- `srcPitch == width` in all logged cases (no pitch anomaly)
- Bias values are tiny (< 0.015 in all cases) → DC correction is working correctly
- `ds = 1.000` for all 1080p clips — parameters are identical regardless of orientation

**Step 2 — Ruled out distortion pass**

User set Distortion Amount = 0 in Premiere. Shift still present.
→ Distortion pass is NOT the cause.

**Step 3 — Ruled out blur and mosaic passes**

User set Distortion Amount = 0, Blur Radius = 0, Mosaic Size = 1.
With these values, all three kernels are pixel-exact copies (`src[y*pitch+x] → dst[y*pitch+x]`).
Shift still present, image position unchanged from the all-enabled case.
→ None of our three processing passes cause the shift.

### Root Cause (revised 2026-07-03, fix implemented — awaiting user verification)

The earlier conclusion ("Premiere compositing bug, nothing we can do") was wrong — the
"even a no-op copy shifts" observation pointed at frame *metadata*, not pixel processing.

Our `Render()` replaced the host-provided `*outFrame` with a frame allocated via
`GPUDeviceSuite::CreateGPUPPix(width, height, …)`. That call takes no bounds origin, so the
replacement frame's bounds always start at (0,0). For effects (unlike transitions) Premiere
delivers `*outFrame` pre-filled with the source pixels, and its bounds carry the clip's
placement inside the sequence frame. For AR-mismatched clips that origin is non-zero
(e.g. a 16:9 clip centered in a 9:16 sequence), and discarding it shifts the clip by exactly
the lost offset — pixel content is irrelevant, which is why the no-op copy still shifted, and
why matched-AR clips (origin 0,0) were unaffected.

**Fix:** operate in place on `*outFrame`, the pattern Adobe's own filter samples
(SDK_ProcAmp_GPU, Vignette_GPU) use — `PrSDKGPUFilter.h` explicitly allows "or operate in
place". The frame keeps its bounds/placement metadata. No aliasing hazard: the multi-pass
chain reads the frame only in the first pass (into tmpA) and writes it only in the last, and
the blackout kernel touches each pixel exactly once.

**To verify:** rebuild + reinstall, apply the effect to a 16:9 clip in a 9:16 sequence (and
vice versa) — the image should no longer move. The `[Anonymizer GPU]` NSLog now also prints
`bounds=` for the frame; for a mismatched clip a non-zero left/top confirms the diagnosis.

### Workaround for Users (obsolete if the fix verifies)

**Nest the clip:**
1. Create a sequence matching the clip's native AR (e.g., 16:9 for a 16:9 clip).
2. Drop the clip into that sequence and apply the effect there.
3. Drop the nested sequence into the target sequence (e.g., 9:16).

The effect now sees a matched-AR frame and Premiere composites the nested sequence into the target
sequence without the GPU-effect compositing bug.

---

## Remaining Cleanup

- [ ] Remove the two temporary `NSLog` debug statements from `src/Anonymizer_GPU.mm` once the AR-shift fix is user-verified (search for `[Anonymizer GPU]`)
- [ ] Rebuild and package OSS edition with all session fixes
- [ ] Sign and notarize the branded edition package
- [ ] Investigate FCP stuttery mask movement (low priority, not yet started)
