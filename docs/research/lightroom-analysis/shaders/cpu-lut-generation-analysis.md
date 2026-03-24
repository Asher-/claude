# CPU LUT Generation Pipeline — CameraRaw.lrtoolkit

Analysis of the curve-to-LUT pipeline in Adobe CameraRaw's CPU-side processing.
Binary: `CameraRaw.lrtoolkit` (ARM64, Mach-O).

## Table of Contents

- [Named Functions](#named-functions)
- [Vtables](#vtables)
- [Constants](#constants)
- [ApplyPreprocessingForFirefly (sub_8f4370)](#applypreprocessingforfirefly-sub_8f4370)
- [ComputeAutoGamma (sub_afd9a0)](#computeautogamma-sub_afd9a0)
- [GetOrCreateCachedGammaCurve (sub_662864)](#getorcreatecachedgammacurve-sub_662864)
- [cr_tone_curve::ChannelToCurve (sub_b9e6c4)](#cr_tone_curvechanneltocurve-sub_b9e6c4)
- [LUT Evaluation Engine](#lut-evaluation-engine)
- [Object Layouts](#object-layouts)
- [Virtual Dispatch Map](#virtual-dispatch-map)
- [BuildColorProfileFromSpec (sub_a4b740)](#buildcolorprofilefromspec-sub_a4b740)
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
| `0x8f4370`  | ApplyPreprocessingForFirefly  |  26 |   968 | WB + linearToNonLinear + domain stretch + auto-gamma for Firefly AI  |
| `0xafe02c`  | (TileStatisticsCollector)     |  65 |  1652 | Collects tile statistics records (0x108 bytes each) by tag           |
| `0xafe7c0`  | (ScopedTimerEnd)              | —   | —     | Ends scoped timing section                                           |
| `0xb05b0c`  | (TopLevelStagePipeline)       | 333 |  9360 | Top-level stage pipeline, also calls ComputeAutoGamma                |
| `0x9bc088`  | InitEvaluatorBase             |   1 |    48 | Base class constructor: sets vtable, LUT resolution=256, defaults    |
| `0x6971f8`  | Destroy3CurveEvaluator        |  12 |   236 | Destructor: releases curve objects, vectors, base class cleanup      |
| `0xa4b740`  | BuildColorProfileFromSpec     |  25 |   524 | Color profile factory: illuminant + primaries + gamma → profile      |
| `0x662264`  | CachedColorProfileFactory     |  11 |   676 | Thread-safe cached factory for color profile objects (0x130 bytes)   |
| `0x66d97c`  | ApplyEvaluatorToData          |   4 |   200 | Alternate evaluation path (arg4 < 2): single-curve LUT application   |
| `0x6625f4`  | BuildGammaOnlyProfile         | —   | —     | Builds a gamma-only color profile (when illuminant type == 1)        |
| `0xbb7410`  | (LUTApplicationDispatch)      |   7 |   280 | Dispatches LUT application: arg4≥2 → multi-curve, else → single      |
| `0x66b6d4`  | (SingleCurveEvaluatorInit)    |   6 |   212 | Creates 0x70-byte single-curve evaluator with LUT + shared_ptr       |
| `0x9bd3ac`  | (NormalizeCurveType)          |   1 |    44 | Maps curve types: 3→3, >2→2, else XOR with 1                         |

## Vtables

| Address     | Name                                 | Object Size | Layout                                         |
| :---------- | :----------------------------------- | :---------- | :--------------------------------------------- |
| `0x7c8ab10` | vtable_GammaCurve                    | 24 bytes    | `{vtable, gamma:f64, 1/gamma:f64}`             |
| `0x7c8ac00` | vtable_GammaCurve_SharedPtrCtrlBlock | 32 bytes    | `{vtable, refcount, weakcount, raw_ptr}`       |
| `0x7c8bb18` | vtable_3CurveEvaluator               | —           | LUT resolution 256                             |
| `0x7cb1990` | vtable_CachedLUTWrapper              | 64+32 bytes | Cached LUT representation + shared_ptr wrapper |
| `0x7ca1c88` | vtable_EvaluatorBaseClass            | ≥0x24 bytes | Base class for curve evaluators                |
| `0x7c8aac8` | vtable_ColorProfile                  | 0x130 bytes | Color profile: illuminant + primaries + gamma  |
| `0x7c8abb0` | vtable_ColorProfile_SharedPtrCtrlBlk | 32 bytes    | `{vtable, refcount, weakcount, raw_ptr}`       |
| `0x7c8d2e0` | vtable_SingleCurveWrapper            | —           | Used in single-curve evaluator init            |

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

## ApplyPreprocessingForFirefly (sub_8f4370)

**Signature** (reconstructed):
```cpp
void* ApplyPreprocessingForFirefly(
    void* context,           // r0 → r20
    void* stageObject,       // r1 → r23 — object with vtable, virtual call at +0x128
    void* unused,            // r2
    void* conditionalArg,    // r3 — if non-null, triggers sub_682aec
    void* domainScaleOut,    // r4 → r25 — passed to ComputeAutoGamma as domainScaleArray
    bool enableAutoGamma,    // r5 → r21 — if true, calls ComputeAutoGamma at the end
    void* configStruct       // r6 — [+0x18] = channelCount, [+0x1c] = mode
);
```

**Scoped timer**: `"ApplyPreprocessingForFirefly : WB + linearToNonLinear(fp32)"`

### Pipeline Sequence

1. **Create processing state**: `sub_79ea6c(context)` → returns new state object
2. **White balance + linear-to-nonlinear** (`sub_86fe34`, mode=2): Core tone mapping conversion
3. **Conditional processing** (`sub_682aec`, flags 1,0,0): Only if `conditionalArg != 0`
4. **Virtual dispatch**: `stageObject->vtable[0x128/8]()` — queries some property
5. **LUT application** (`sub_bb7410`): Called with `channelCount` and mode=1, only if a condition from step 4 passes and `sub_bc5874` bit 5 is clear
6. **Special mode path** (`sub_683048`): Only when `mode == 0xb (11)`, with channelCount and flag=1
7. **Statistics extraction** (`sub_9f4ba8`, `loc_9a5694`, `sub_870098`, `sub_9a97b4`, `loc_9f4e7c`): Computes per-channel bounds
8. **Min/max channel sweep**: Loops channels 1..N finding global min and max from extracted bounds
9. **Domain stretch table fill**: Same float[3] pattern as ComputeAutoGamma Phase 2:
   - Forward: `[min, 0, -1/(min-max)]`
   - Inverse: `[0, min, max-min]`
10. **AutoStretching** (conditional): If domain tables have non-trivial range, runs `"ApplyPreprocessingForFirefly :AutoStretching"` via `sub_afd894` and swaps in the stretched state
11. **ComputeAutoGamma** (optional): Only if `enableAutoGamma` flag is set

### Callers

| Caller       | Notes                         |
| :----------- | :---------------------------- |
| `sub_8f142c` | Upstream Firefly orchestrator |
| `sub_a6a3b0` | Alternate entry point         |

### Key Insight

The Firefly AI preprocessing pipeline reuses the same LUT infrastructure (`sub_bb7410`) and auto-gamma system (`ComputeAutoGamma`) as the standard tone curve pipeline. This confirms these are shared CameraRaw primitives, not Firefly-specific code.

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

## Object Layouts

### EvaluatorBase (InitEvaluatorBase at 0x9bc088)

```
+0x00: void*   vtable          (0x7ca1c88)
+0x08: int32   flags           (init: 0)
+0x0c: uint16  lutResolution   (init: 0x100 = 256)
+0x10: int32   evaluationMode  (init: 4)
+0x14: uint16  isEnabled       (init: 1)
+0x18: void*   curveData       (init: null)
+0x20: uint8   isDirty         (init: 0)
```

Minimum size: ~0x24. All evaluator subclasses call InitEvaluatorBase first, then overwrite the vtable pointer with their own.

### 3CurveEvaluator (Init3CurveEvaluator at 0x676ae8)

Total size: **0x1A0 (416 bytes)**. Mode argument (bit 0) selects direct vs indirect evaluation.

```
+0x00:  void*    vtable              (overwritten to 0x7c8bb18)
+0x08–0x20: EvaluatorBase fields
+0x28:  void*    sharedResource      (released in destructor)
+0x30:  vector   lutBuffer1          (0x20 bytes, capacity 0x1000 = 4096)
+0x50:  vector   lutBuffer2          (ditto)
+0x70:  vector   lutBuffer3          (ditto)
+0x90:  void*    curveObject1        (direct mode: wrapped curve; released in destructor)
+0xD8:  void*    curveObject2        (ditto)
+0x120: void*    curveObject3        (ditto)
+0x168: void*    auxRef1             (released in destructor)
+0x170: void*    auxRef2             (released in destructor)
+0x178: void*    auxRef3             (released in destructor)
+0x180: int32    transferFuncType1   (2 or 3, from Configure3CurveEvaluator)
+0x184: int32    transferFuncType2   (2 or 3)
+0x188: int32    transferFuncType3   (2 or 3)
+0x19c: uint8    mode                (1=direct, 0=indirect)
```

**Direct mode** (mode=1): Curves stored at +0x90/+0xD8/+0x120 as wrapped curve objects; evaluation deferred.
**Indirect mode** (mode=0): LUT resolution set to 256; `Configure3CurveEvaluator` calls `EvaluateCurveToLUT` three times to pre-fill LUT buffers at +0x30/+0x50/+0x70.

### ColorProfile (CachedColorProfileFactory at 0x662264)

Total size: **0x130 (304 bytes)**. Vtable at `0x7c8aac8`.

```
+0x00:  void*    vtable          (0x7c8aac8)
...     (matrix data from sub_65b600 + sub_111abd4)
+0x128: void*    gammaCurve      (GammaCurve or null)
```

Created from illuminant whitepoint + RGB primaries + gamma curve. Thread-safe global cache at `0x8001a70` (mutex-protected).

---

## Virtual Dispatch Map

Two distinct class hierarchies participate in the LUT pipeline.

### Curve Hierarchy (mathematical functions)

Objects: GammaCurve (24 bytes), and other curve types. Used as `arg2` in `EvaluateCurveToLUT`.

| Offset | Slot | Method                          | Evidence                                                                           |
| :----- | ---: | :------------------------------ | :--------------------------------------------------------------------------------- |
| +0x00  |    0 | Complete destructor             | Standard Itanium ABI                                                               |
| +0x08  |    1 | Deleting destructor / release   | Called in destructor cleanup, EvaluateCurveToLUT buffer swap                       |
| +0x10  |    2 | getOrShareBuffer(size) → void*  | EvaluateCurveToLUT arg1: allocates, returns object with data at +0x10              |
| +0x18  |    3 | **evaluate(double x) → double** | EvaluateCurveToLUT arg2: core evaluation, called in direct loop and adaptive modes |

Note: vtable+0x10 on different curve types may serve different roles (buffer management vs isEmpty check) depending on the subclass hierarchy branch.

### Evaluator Hierarchy (pipeline objects)

Objects: EvaluatorBase → 3CurveEvaluator (0x1A0 bytes), and other subclasses. These manage 3 curves and their pre-computed LUTs.

The evaluator objects are primarily operated on through **non-virtual** methods (`InitEvaluatorBase`, `Configure3CurveEvaluator`, `EvaluateCurveToLUT`). Virtual dispatch appears limited to:

| Offset | Slot | Method              | Evidence                                                 |
| :----- | ---: | :------------------ | :------------------------------------------------------- |
| +0x00  |    0 | Destructor          | Standard Itanium ABI; Destroy3CurveEvaluator at 0x6971f8 |
| +0x08  |    1 | Deleting destructor | Called on contained objects during cleanup               |

The evaluator hierarchy vtable appears smaller than expected — most functionality is dispatched through direct calls rather than virtual methods, with polymorphism handled at the **curve level** rather than the evaluator level.

---

## BuildColorProfileFromSpec (sub_a4b740)

**Signature** (reconstructed):
```cpp
bool BuildColorProfileFromSpec(
    void* colorSpaceSpec,    // r0 → r20 — struct with illuminant/primaries/gamma fields
    void* arg1,              // r1 — passed to sub_3f65b0
    void** outProfile        // r2 → r19 — receives the color profile object
);
```

### Logic

1. Checks `spec[0x14]` — if `0xffff`, enters **gamma-based** path
2. Loads gamma value from `spec + 0x58` (`spec[0xb]` as double)
3. If gamma > -0.4, calls `GetOrCreateCachedGammaCurve(gamma)` → GammaCurve*
4. Two-level switch selects illuminant and primaries:

   **Illuminant** (from `spec[0x0]`):
| Value | Illuminant | Whitepoint (x, y)  |
| :---- | :--------- | :----------------- |
|     0 | (identity) | —                  |
|     1 | sRGB/D65   | (0.3127, 0.3127)   |
|     2 | Custom     | from spec+0x08     |
|     3 | D50        | (0.314, 0.314)     |
|     4 | Other      | from data constant |

   **Primaries** (from `spec[0x6]`):
| Value   | Standard  | R          | G          | B          |
| :------ | :-------- | :--------- | :--------- | :--------- |
|       1 | sRGB      | from data  | (0.30, ?)  | (0.15, ?)  |
|       2 | Custom    | from spec  | from spec  | from spec  |
|       3 | (none)    | —          | —          | —          |
|       4 | Adobe RGB | (0.708, ?) | (0.17, ?)  | (0.131, ?) |
| default | Rec.709   | (0.68, ?)  | (0.265, ?) | (0.15, ?)  |

5. Calls `CachedColorProfileFactory(whitepoint, primariesR, primariesG, primariesB, gammaCurve)` → profile
6. If `spec[0x0]` == 1 (direct gamma), calls `BuildGammaOnlyProfile(gammaCurve)` instead

### Key Insight

This function is the **bridge between the auto-gamma pipeline and the color management system**. The GammaCurve objects produced by `ComputeAutoGamma` and `GetOrCreateCachedGammaCurve` flow into color profiles that combine gamma correction with illuminant adaptation and gamut mapping.

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
26. **Firefly AI preprocessing** reuses the same LUT infrastructure (`sub_bb7410`) and auto-gamma system as the standard tone curve pipeline — these are shared CameraRaw primitives
27. **ApplyPreprocessingForFirefly** performs WB + linearToNonLinear (fp32), then domain stretch, then optional auto-gamma — the full preprocessing chain for generative AI input
28. **Domain stretch is computed twice**: once inside ComputeAutoGamma from tile statistics, and once inside the Firefly preprocessor from per-channel bounds extraction — same float[3] table format

### New (29-36)

29. **EvaluatorBase is a thin base class** (~0x24 bytes) initialized by `InitEvaluatorBase` — sets vtable, LUT resolution=256, default flags. All evaluator subclasses inherit this layout.
30. **3CurveEvaluator is 0x1A0 (416) bytes** with a mode bit at +0x19c selecting between direct (curves at +0x90/+0xD8/+0x120) and indirect (pre-filled LUTs at +0x30/+0x50/+0x70) evaluation.
31. **Two class hierarchies** participate: curve objects (GammaCurve etc.) with vtable+0x18 = evaluate(double→double), and evaluator objects (3CurveEvaluator etc.) that manage curve collections and LUT caches. Polymorphism lives at the curve level; evaluators dispatch mostly through direct calls.
32. **BuildColorProfileFromSpec** is a color profile factory that combines illuminant + primaries + gamma into cached color space objects — the bridge from auto-gamma to full color management.
33. **Color profiles are 0x130 bytes** with the GammaCurve stored at +0x128, cached in a global thread-safe map at 0x8001a70. Separate cache from gamma curves (0x8001a98).
34. **Illuminant/primaries selection** follows standard color science: sRGB/D65 (0.3127), D50 (0.314), Adobe RGB (0.708/0.17/0.131), Rec.709 (0.68/0.265/0.15), plus custom values from the spec struct.
35. **LUT application dispatches** in sub_bb7410 based on arg4: ≥2 goes to multi-curve path (sub_bb6384, 56 BBs), <2 goes to single-curve path (sub_66d97c → sub_66b6d4).
36. **The -0.4 gamma threshold** appears in both ComputeAutoGamma (secondary gamma decision) and BuildColorProfileFromSpec (gamma range check), reinforcing this as a system-wide under-exposure boundary.

---

## Remaining Work

- [ ] **sub_bb2948** (205 BBs): Assembly trace of full call sequence and domain transforms. Too large to decompile.
- [x] **sub_66d97c**: Alternate evaluation path — decompiled. Single-curve path for arg4 < 2.
- [ ] **sub_bb458c, sub_bb4840**: The two resolution paths in Get1dFunctionIds.
- [ ] **sub_686d38 cache internals**: sub_410538 (cache lookup) and sub_6870e0 (cache insert).
- [x] **Vtable method mapping**: Both hierarchies documented. Curve vtable: +0x18=evaluate(double→double). Evaluators use mostly non-virtual dispatch.
- [x] **sub_8f4370**: ApplyPreprocessingForFirefly — decompiled and documented.
- [x] **sub_a4b740**: BuildColorProfileFromSpec — color profile factory bridging gamma to full color management. Decompiled and documented.
- [ ] **sub_afe02c** (65 BBs): The tile statistics collector — understand what data source it reads and how the 0x108-byte records are structured.
- [ ] **sub_8f142c, sub_a6a3b0**: Callers of ApplyPreprocessingForFirefly — trace upstream Firefly orchestration.
- [ ] **sub_86fe34**: WB + linearToNonLinear implementation (called with mode=2).
- [ ] **sub_b05b0c** (333 BBs): Top-level stage pipeline — the other ComputeAutoGamma caller. Too large to decompile.
- [ ] **sub_662264 internals**: CachedColorProfileFactory — understand sub_65b600 (matrix setup from illuminant+primaries) and sub_111abd4 (matrix computation).
- [ ] **sub_bb6384** (56 BBs): Multi-curve LUT application path — the sRGB log encoding / luma-vs-nonluma dispatch.
- [ ] **sub_bb7590** (48 BBs): Caller of BuildComposite3CurveEvaluator — understand full evaluator lifecycle.
- [ ] **GammaCurve evaluate method**: Identify the actual pow() implementation stored at vtable+0x18 for GammaCurve objects.
