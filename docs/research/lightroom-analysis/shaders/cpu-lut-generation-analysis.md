# CPU LUT Generation Pipeline — CameraRaw.lrtoolkit

Analysis of the curve-to-LUT pipeline in Adobe CameraRaw's CPU-side processing.
Binary: `CameraRaw.lrtoolkit` (ARM64, Mach-O).

## Table of Contents

- [Named Functions](#named-functions)
- [Vtables](#vtables)
- [Constants](#constants)
- [ComputeAutoGamma (sub_afd9a0)](#computeautogamma-sub_afd9a0)
- [GetOrCreateCachedGammaCurve (sub_662864)](#getorcreatecachedgammacurve-sub_662864)
- [cr_tone_curve::ChannelToCurve (sub_b9e6c4)](#cr_tone_curvechanneltocurve-sub_b9e6c4)
- [LUT Evaluation Engine](#lut-evaluation-engine)
- [Implications](#implications)
- [Remaining Work](#remaining-work)

---

## Named Functions

| Address     | Name                          | BBs | Bytes | Description                                                          |
| :---------- | :---------------------------- | --: | ----: | :------------------------------------------------------------------- |
| `0xafd9a0`  | ComputeAutoGamma              |  42 |  1452 | Computes auto gamma from tile statistics, domain stretch, tone curve |
| `0x662864`  | GetOrCreateCachedGammaCurve   |  25 |   524 | Thread-safe cached factory for GammaCurve objects                    |
| `0xb9e6c4`  | cr_tone_curve::ChannelToCurve |   6 |   208 | Converts channel int32 control points to normalized tone curve       |
| `0x677e3c`  | BuildComposite3CurveEvaluator | —   |   416 | Factory creating composite 3-curve evaluator objects                 |
| `0x676ae8`  | Init3CurveEvaluator           | —   | —     | LUT resolution 256, two modes (direct vs indirect)                   |
| `0x676d60`  | Configure3CurveEvaluator      | —   | —     | Stores 3 curves in mode-dependent slots                              |
| `0x1115204` | EvaluateCurveToLUT            | —   | —     | Core LUT fill: direct loop (256 entries) or adaptive subdivision     |
| `0x11150c8` | AdaptiveMidpointLUTFill       | —   | —     | Recursive midpoint refinement, epsilon = abs(diff) * (1/256)         |
| `0xbb682c`  | WrapCurveAsLUTObject          | —   | —     | 64-byte cached LUT + 32-byte shared_ptr wrapper                      |
| `0x686d38`  | CachedLUTBuilder              | —   | —     | Thread-safe with std::mutex, typed curve table entries               |
| `0xb9effc`  | Get_sRGB_Log_DecodeTable      | —   | —     | Lazy singleton, GPU-accessible via Metal buffers                     |
| `0xafe02c`  | (TileStatisticsCollector)     |  65 |  1652 | Collects tile statistics records (0x108 bytes each) by tag           |
| `0xafe7c0`  | (ScopedTimerEnd)              | —   | —     | Ends scoped timing section                                           |

## Vtables

| Address     | Name                                 | Object Size | Layout                                         |
| :---------- | :----------------------------------- | :---------- | :--------------------------------------------- |
| `0x7c8ab10` | vtable_GammaCurve                    | 24 bytes    | `{vtable, gamma:f64, 1/gamma:f64}`             |
| `0x7c8ac00` | vtable_GammaCurve_SharedPtrCtrlBlock | 32 bytes    | `{vtable, refcount, weakcount, raw_ptr}`       |
| `0x7c8bb18` | vtable_3CurveEvaluator               | —           | LUT resolution 256                             |
| `0x7cb1990` | vtable_CachedLUTWrapper              | 64+32 bytes | Cached LUT representation + shared_ptr wrapper |
| `0x7ca1c88` | vtable_EvaluatorBaseClass            | —           | Base class for curve evaluators                |

## Constants

| Value                                  | Meaning                                          |
| :------------------------------------- | :----------------------------------------------- |
| `0x3e45798ee0000000`                   | epsilon ~ 7.45e-9, prevents log(0)               |
| `0xbfe62e42fefa39ef`                   | -ln(2) ~ -0.6931, divisor for log2 conversion    |
| `0xbfd999999999999b`                   | -0.4, threshold for secondary gamma correction   |
| `0x3ff0c28f5c28f5c3`                   | 1.05, minimum gamma for cached factory           |
| `0x4024000000000000`                   | 10.0, maximum gamma for cached factory           |
| `0x322bcc77`                           | Hash tag for "AutoGamma" statistics query        |
| `0x108` (264)                          | Tile statistics record stride                    |
| `0xa4` (164)                           | Per-channel tone curve data stride               |
| `0x3f70101010101010`                   | ~1/256, normalizes int32 control points to [0,1] |
| `kCurveTableTypeSlopeExtendedFunction` | = 3, typed curve table entry kind                |

---

## ComputeAutoGamma (sub_afd9a0)

**Signature** (reconstructed):
```cpp
void ComputeAutoGamma(
    void* context,          // r0 → r20
    void** stagePtr,        // r1 → r21 — stage object, [+0x18] = channel count
    shared_ptr<GammaCurve>* outPrimaryGamma,   // r2 → r25
    float* domainScaleArray,     // r3 → r23 — float[3] per channel
    float* domainInverseArray,   // r4 → r24 — float[3] per channel
    shared_ptr<GammaCurve>* outStretchGamma,   // r5 → r22
    void* outputCurveObj         // r6 → r19
);
```

### Phase 1 — Primary Auto-Gamma

1. Opens scoped timer `"AutoGamma"` via `sub_bc82cc`
2. Calls `sub_afe02c(context, *stagePtr, tag=0x322bcc77, &buffer)` to collect tile statistics
3. Returns an array of **0x108-byte (264) records** with a luminance field at byte offset **0xB0**
4. Sums luminance across all tiles (with 4x unrolled loop for >3 entries)
5. Computes average: `avg = sum / count`
6. Computes gamma:
   ```
   gamma = ln(avg + 7.45e-9) / (-ln(2))
         = -log2(avg + epsilon)
   ```
   Clips via `fminnm` to some maximum
7. Creates a **GammaCurve** object (vtable `0x7c8ab10`):
   ```
   [0x00] vtable
   [0x08] gamma      (f64)
   [0x10] 1.0/gamma  (f64, reciprocal for inverse)
   ```
8. Wraps in `shared_ptr` (control block vtable `0x7c8ac00`) and stores in `outPrimaryGamma`

### Phase 2 — Domain Stretch Statistics

1. Calls `sub_afe02c` again with the same tag
2. Iterates records, tracking:
   - Sum of field at byte offset 0xB0 (luminance, same as phase 1)
   - **Global minimum** across field at byte offset 0x68 (per-tile min)
   - **Global maximum** across field at byte offset 0xA0 (per-tile max)
3. Reads `N = *(int32_t*)(*stagePtr + 0x18)` — the channel count
4. For each of N channels, fills two `float[3]` entries:

   **domainScaleArray** (forward map [min,max] -> [0,1]):
   ```
   [min, 0.0, -1.0/(min - max)]   if min != max
   [min, 0.0, 0.0]                 if min == max
   ```

   **domainInverseArray** (inverse map):
   ```
   [0.0, min, max - min]           if min != max
   [0.0, min, 0.0]                 if min == max
   ```

### Phase 3 — Post-Stretch Secondary Gamma

1. Creates `"AutoGamma-Stretch"` marker
2. Calls `sub_79ea38(context, *stagePtr)` to apply the domain stretch to the stage
3. Swaps the stretched stage into `*stagePtr` (with refcount management)
4. Computes post-stretch correction from the accumulated sum and domain bounds:
   ```
   s0 = (float)accumulated_sum - domainScaleArray[0]   // post-stretch luminance minus min
   s8 = fmadd(s1, s0, s2)                               // linear combination
   d9 = (double)s8
   ```
5. **If d9 < -0.4**: creates a second GammaCurve with the same `-log2(val + eps)` formula and stores in `outStretchGamma`

   This secondary gamma kicks in when the post-stretch analysis reveals significant under-exposure.

### Phase 4 — Tone Curve Generation

1. One-time init: `sub_9cd0b8(2)` — initializes a 2-channel tone curve representation (guard variable at `0x8019678`)
2. Calls `cr_tone_curve::ChannelToCurve(0x8019708, outputCurveObj, channel=0)` to generate the final tone curve from a global channel data table

### Callers

| Caller       | BBs | Bytes | Notes                            |
| :----------- | --: | ----: | :------------------------------- |
| `sub_8f4370` |  26 |   968 | Smaller orchestrator             |
| `sub_b05b0c` | 333 |  9360 | Top-level stage pipeline (large) |

---

## GetOrCreateCachedGammaCurve (sub_662864)

**Signature**: `shared_ptr<GammaCurve> GetOrCreateCachedGammaCurve(double gamma)`

1. **Range check**: gamma must be in `[1.05, 10.0]`, else returns `nullptr`
2. **Hash key**: builds an 8-byte key from the gamma double value
3. **Cache lookup**: locks mutex at `0x7d58e60`, searches global cache at `0x8001a98` via `sub_413cec`
4. **Cache hit**: returns existing `shared_ptr` from cache entry offset 0x20
5. **Cache miss**: allocates new GammaCurve, wraps in `shared_ptr`, inserts via `sub_664138`
6. Unlocks and returns

**Caller**: `sub_a4b740` (25 BBs, 524 bytes)

---

## cr_tone_curve::ChannelToCurve (sub_b9e6c4)

**Signature**: `void cr_tone_curve::ChannelToCurve(void* tone_data, void* output_curve, int channel)`

From `reMedia.framework/.../CoreMedia`.

1. Validates `channel < 4`, else throws `"Bad channel in cr_tone_curve::ChannelToCurve"`
2. Computes channel data pointer: `data = tone_data + channel * 0xa4`
3. Reads point count: `count = *(int32_t*)data`
4. Resets output curve via `sub_1090630(output_curve)`
5. Iterates control points (int32 pairs at stride 8, starting at `data + 8`):
   - Converts each int32 to double, scales by ~1/256
   - Adds point via `sub_109064c(output_curve, x, y)`
6. Finalizes via virtual call at vtable offset 0x28

**Channel data layout** (164 bytes per channel):
```
[0x00] int32  count       — number of control points
[0x04] int32  pad/first_x
[0x08] int32  point pairs — {x, y} as int32, stride 8
...
max ~19 control points per channel
```

---

## LUT Evaluation Engine

(From prior sessions — see handoff v4 for full details)

### Core Pipeline

1. **3-Curve Evaluator** (vtable `0x7c8bb18`): Takes 3 curves, LUT resolution 256
   - **Direct mode** (flag bit 0 = 0): Evaluates all 256 entries in a loop
   - **Indirect mode** (flag bit 0 = 1): Uses adaptive subdivision
2. **EvaluateCurveToLUT** (`0x1115204`): Core fill function dispatching to the two modes
3. **AdaptiveMidpointLUTFill** (`0x11150c8`): Recursive midpoint refinement
   - Evaluates curve at midpoint between two known values
   - If `|actual - interpolated| > epsilon` where `epsilon = |diff| * (1/256)`, recurse
   - Otherwise, linear interpolation fills the gap
4. **WrapCurveAsLUTObject** (`0xbb682c`): Wraps 256-entry LUT in 64-byte cached object + 32-byte shared_ptr
5. **CachedLUTBuilder** (`0x686d38`): Thread-safe builder with `std::mutex`, typed curve table entries (`kCurveTableTypeSlopeExtendedFunction = 3`)
6. **sRGB Log Tables**: `Get_sRGB_Log_DecodeTable` (`0xb9effc`) — lazy singleton, GPU-accessible via Metal buffers

### Key Analysis from sub_bb6384

56 basic blocks. Non-luma/luma modes with sRGB log encoding paths. Error string: `'cr_stage_rgb_tone::Initialize in Luma mode requires negative'`.

---

## Implications

### From prior sessions (1-18)

1. The LUT system uses 256-entry tables as its standard resolution
2. Two evaluation strategies: brute-force (all 256) vs adaptive subdivision
3. Adaptive subdivision uses relative epsilon: `|diff| * (1/256)` — tighter tolerance for larger value changes
4. The curve evaluator is polymorphic (vtable-based) with a base class at `0x7ca1c88`
5. Thread-safe caching with `std::mutex` for both LUT objects and gamma curves
6. `shared_ptr` control blocks are used throughout for reference-counted ownership
7. sRGB log encode/decode tables are lazy singletons, GPU-accessible via Metal
8. The 3-curve evaluator stores curves in mode-dependent slot offsets within the object
9. `kCurveTableTypeSlopeExtendedFunction = 3` identifies slope-extended function curves in the cache
10. The `cr_stage_rgb_tone` stage has distinct luma and non-luma initialization paths
11. Non-luma path uses sRGB log encoding as an intermediate domain
12. Luma path requires a "negative" parameter (based on error string)
13. The composite evaluator factory (416 bytes) follows the same pattern as the 256-byte builders
14. Curve-to-LUT evaluation is the bridge between the parametric curve representation and the discrete GPU-consumable LUT
15. The adaptive fill recursion depth is bounded by the LUT resolution (256 entries max between any two evaluated points)
16. The LUT cache avoids redundant curve evaluation for repeated identical curves
17. The sRGB log domain is used as a perceptually uniform working space for tone operations
18. The evaluator base class likely has virtual methods for evaluate, destroy, and possibly clone

### New (19-25)

19. **Auto-gamma** is computed from image tile statistics as `gamma = -log2(avg_luminance + epsilon)` — log2 of the reciprocal average luminance
20. **Tile statistics records** are 264 bytes (0x108) with luminance at offset 0xB0, per-tile min at 0x68, per-tile max at 0xA0
21. **Domain stretching** maps the global [min, max] luminance range to [0, 1] using a linear float[3] transform per channel
22. **Post-stretch secondary gamma** is conditionally applied when the correction factor falls below -0.4, indicating significant under-exposure
23. **GammaCurve objects** are 24 bytes `{vtable, gamma, 1/gamma}` — forward and inverse exponents stored together
24. **Cached gamma factory** at `sub_662864` restricts gamma to [1.05, 10.0] and uses a separate thread-safe global cache (mutex at `0x7d58e60`, cache at `0x8001a98`)
25. **cr_tone_curve::ChannelToCurve** uses 164-byte per-channel data with int32 control points scaled by ~1/256, max ~19 points per channel, from `reMedia.framework/CoreMedia`

---

## Remaining Work

- [ ] **sub_bb2948** (205 BBs): Assembly trace of full call sequence and domain transforms. Too large to decompile.
- [ ] **sub_66d97c**: Alternate evaluation path used by sub_bb7410 when arg4==1.
- [ ] **sub_bb458c, sub_bb4840**: The two resolution paths in Get1dFunctionIds.
- [ ] **sub_686d38 cache internals**: sub_410538 (cache lookup) and sub_6870e0 (cache insert).
- [ ] **Vtable method mapping**: evaluator base class (0x7ca1c88) and 3-curve evaluator (0x7c8bb18) virtual methods.
- [ ] **sub_8f4370**: The 26-BB orchestrator that calls ComputeAutoGamma — trace its full pipeline.
- [ ] **sub_a4b740**: Caller of GetOrCreateCachedGammaCurve — understand when the cached path is used vs the direct ComputeAutoGamma path.
- [ ] **sub_afe02c** (65 BBs): The tile statistics collector — understand what data source it reads and how the 0x108-byte records are structured.
