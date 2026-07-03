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

### Root Cause

**The shift is caused by Premiere Pro's compositing pipeline, not by our effect.**

When any GPU effect is applied to an AR-mismatched clip, Premiere uses a different compositing
transform for the clip than it uses without an effect. Since a no-op effect (pixel-exact copy)
also causes the shift, there is nothing in our pixel processing that can fix or prevent it.
The shift happens in Premiere's step after `Render()` returns.

This appears to be a Premiere bug / limitation in the Mercury GPU Acceleration compositing path
for AR-mismatched clips with GPU effects applied.

### What We Still Don't Know

The NSLogs shown in the previous Console.app session were captured for matched-AR scenarios.
We have not confirmed what frame dimensions Premiere passes to the GPU effect for mismatched-AR clips.
This matters because:

- **If Premiere passes sequence dimensions (e.g., 1080×1920 for the portrait sequence):** the compositing
  transform is applied after our effect's output, and we have no way to compensate.
- **If Premiere passes clip dimensions (e.g., 1920×1080 for the landscape clip):** Premiere scales/positions
  our output when compositing, and a pre-shift in our output might be able to compensate — though we'd
  need to know the expected placement from within the GPU filter.

**To get this data:** apply the no-op params (Amount=0, Blur=0, Mosaic=1) to a mismatched-AR clip in Premiere,
then read Console.app for `[Anonymizer GPU]` entries. Compare `w=` and `h=` to the sequence dimensions.

### Workaround for Users

**Nest the clip:**
1. Create a sequence matching the clip's native AR (e.g., 16:9 for a 16:9 clip).
2. Drop the clip into that sequence and apply the effect there.
3. Drop the nested sequence into the target sequence (e.g., 9:16).

The effect now sees a matched-AR frame and Premiere composites the nested sequence into the target
sequence without the GPU-effect compositing bug.

---

## Remaining Cleanup

- [ ] Remove the temporary `NSLog` debug statements from `src/Anonymizer_GPU.mm` (lines 168–170 and 241–244)
- [ ] Rebuild and package OSS edition with all session fixes
- [ ] Sign and notarize the branded edition package
- [ ] Investigate FCP stuttery mask movement (low priority, not yet started)
