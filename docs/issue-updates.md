# 已发布到 flutter/flutter#194433 的评论原文

> 依次对应：① 现象与 A/B 复现 ② 归因 + 最小复现 + 25 pass/帧 ③ 材料仓库

---

## 评论 1

### Update: quantitative A/B comparison — Impeller vs Skia on the same machine

We profiled the same interaction (continuously moving the pointer across the UI, which drives the hover-driven repaints that stutter) under both renderers, same app, same machine, same session conditions.

**Method**

- `flutter run -d linux` (Impeller, the 3.47 default) vs `flutter run -d linux --no-enable-impeller` (Skia).
- Per-frame `FrameTiming` logged from a temporary `SchedulerBinding.instance.addTimingsCallback` (buildDuration / rasterDuration / vsyncOverhead / totalSpan).
- Engine-side timeline pulled over the VM Service (`getVMTimeline` with all streams enabled, B/E events paired). Note the timeline ring buffer only retains roughly the last ~3 s of events, which is why the raster-frame counts below are small.

**Per-frame FrameTiming (last 400 frames of the hover interaction)**

| | n | build median | raster median | raster p90 | raster >16ms | totalSpan median |
|---|---|---|---|---|---|---|
| Impeller | 400 | 5.21 ms | **11.55 ms** | 15.20 ms | 7% | **22.40 ms** |
| Skia | 329 | 6.55 ms | **5.18 ms** | 7.18 ms | 1% | **15.77 ms** |

**Raster thread, per frame (timeline)**

| | frames | `GPURasterizer::Draw` mean | max |
|---|---|---|---|
| Impeller | 24 | **12.07 ms** | 28.1 ms |
| Skia | 37 | **5.62 ms** | 9.1 ms |

**Where Impeller's 12.07 ms/frame goes**

- `Rasterizer::DrawToSurfaces` 12.03 ms (i.e. essentially all of it)
  - `ReactorGLES::React` / `FlushOps` (GL command submission) 4.47 ms — 4185 `ReactorGLES::Operation` over 24 frames (≈174 operations per frame)
  - `FlutterCompositorPresentLayers` (present) 3.33 ms — the same event under Skia is 0.57 ms, roughly 6× faster
- `CreateGlyphAtlas` 0.10 ms → the SDF text path does not look like the bottleneck
- UI thread: `buildDuration` is *lower* with Impeller (5.21 ms vs 6.55 ms) → the regression is purely raster-side, nothing Dart-side.

**Takeaways**

1. On this hardware the Impeller raster thread costs ~2.2× Skia per frame, which pushes `totalSpan` (22.4 ms median) above the 16.6 ms budget and produces the visible stutter; Skia sits right at the budget (15.8 ms).
2. The extra cost is in GL submission plus present/composite — not in text/glyph atlas, and not on the UI thread.
3. Our UI does contain blur-heavy layers (glass surfaces / backdrop filters) plus several custom painters (table, heatmap, 3D view). Next step on our side is to reduce this to a minimal sample to isolate which of those dominates (blur vs many small draws vs the present path); we will post that here.

Happy to run any additional instrumentation (e.g. a build from a specific engine revision or extra engine-side timers) if that helps.

---

## 评论 2

### Update 2: narrowed to gradient-heavy drawing + a render-pass question for the GL backend

We now have a reproducible, quantified story. All measurements below are on the same machine (Ubuntu 24.04.3, Wayland, AMD Radeon Vega 8 / Mesa 25.2.8, Flutter 3.47.7, debug builds, window 1280x720 logical @2x = 2560x1440 physical).

#### 1. Real app, measured automatically (no manual interaction)

We added a temporary env-gated flag to our app that enters its built-in simulated-data mode (60 fps source, UI updates throttled to ~100 ms) and logs `FrameTiming` per frame. 20 s steady state each:

| renderer | frames in 20 s | build median | raster median | raster p90 | vsync median | totalSpan median |
|---|---|---|---|---|---|---|
| Impeller | 206 | 23.70 ms | **11.87 ms** | 14.81 ms | 9.23 ms | **45.40 ms** |
| Skia | 358 | 13.20 ms | **5.25 ms** | 6.32 ms | 2.06 ms | **20.79 ms** |

raster ratio **2.26×**, and Skia completes 74 % more frames in the same wall time — which is what the user perceives as stutter.

#### 2. Feature bisection inside the real app

Disabling individual decoration features (env-gated, same measurement method):

| variant | raster median | delta |
|---|---|---|
| baseline (all on) | 12.02 ms (200 frames) | — |
| no aurora background (7 radial gradients + wash + grid) | 9.71 ms (347 frames) | −19 % |
| **no glass-surface decorations** (gradient fill + border + highlight + shadow + ClipRRect) | **6.75 ms (351 frames)** | **−44 %** |
| no history chart | 12.20 ms | ~0 % |
| no table text | 12.23 ms | ~0 % |

Fine-grained: no shadow −3 %, no ClipRRect −8 %, **no gradient fill −19 %**, **no highlight overlay (second gradient) −16 %**, no backdrop blur −9 %.
So the two full-panel linear gradients per glass surface are the dominant cost; these are large (panel-sized) fills. Note our glass surfaces are mostly not `BackdropFilter`s — they are gradient-filled translucent rectangles.

#### 3. Minimal reproducer (synthetic, ~40 lines per scenario)

A standalone debug app that repaints continuously from a `Ticker` (no input needed), 5 scenarios:

| scenario | Impeller raster median | Skia raster median | ratio |
|---|---|---|---|
| full-screen solid color (control) | 0.59 ms | 0.62 ms | 0.96× |
| full-screen 2-stop linear gradient | 1.06 ms | 0.81 ms | 1.30× |
| 9 rounded panels, each with a linear gradient + border | **2.03 ms** | **1.04 ms** | **1.95×** |
| full-screen 3-stop radial gradient | 1.01 ms | 0.80 ms | 1.26× |
| "aurora-like": 7 radial gradient blobs (radius ≈ 0.8–1.1× shortestSide) + 1 full-screen linear wash + ~46 grid lines | **2.56 ms** | **1.14 ms** | **2.24×** |

Control scenario is at parity, so the difference is specific to gradient fills, not to filling pixels in general.

#### 4. Engine timeline of the minimal reproducer (Impeller, raster thread)

Running the aurora-like scenario and pulling the VM timeline:

```
GPURasterizer::Draw                        102 frames (1/frame)   318.4 ms →  3.12 ms/frame
└ Rasterizer::DrawToSurfaces              102                     315.5 ms →  3.09 ms/frame
  └ RenderPassGLES::EncodeCommandsInReactor  2550 events         → 25 render passes per frame
     (each ~0.02 ms; only ~0.5 ms/frame of CPU time in the encoder)
```

- **Zero texture-upload events** on the raster thread in this scene (no `TexImage2DInitialization`), so "gradient color-ramp re-uploaded every frame" is **not** the explanation.
- The scene is ~9 gradient draws + grid lines, yet the GL backend records **~25 render passes per frame**.

In the real app the same picture shows up at scale: `ReactorGLES::React`/`FlushOps` 3.83 ms/frame (~153 `ReactorGLES::Operation` per frame) and `FlutterCompositorPresentLayers` 3.37 ms/frame, where the same event under Skia is 0.50 ms; Skia instead spends 3.12 ms in `EmbedderExternalView::Render`.

#### 5. What we would like to know

1. Is issuing a separate render pass per (blended) draw the expected behaviour of the Impeller GL backend on Linux? Are consecutive draws that could share a pass currently batched at all, and is batching on the roadmap?
2. Given the reproducer (solid = parity, gradient-filled panels = 1.95×, gradient blobs = 2.24×), is the fill-rate/render-pass overhead the accepted cause, or is there a known issue/optimisation we should follow instead of attempting a fix?
3. If a PR that reduces the number of passes (or avoids a pass for simple gradients) is welcome, we are willing to attempt it — we would first need to set up the engine build environment; guidance on where to start in `impeller` would be very helpful.

We can attach the complete minimal reproducer project (single `main.dart`, no plugins), the raw `FrameTiming` logs, and the VM timeline JSONs (~5.7 MB) — say the word and we will upload them.

---

## 评论 3

All the material is now uploaded to a standalone public repository:

**https://github.com/kevinsoul/impeller-linux-gradient-repro**

| path | contents |
|---|---|
| `repro/` | the minimal Flutter reproducer (5 scenarios, ticker-driven repaint, **no mouse input required**, auto-exits after the last scenario) |
| `logs/` | raw per-frame `FrameTiming` logs — reproducer (`grad_impeller.log` / `grad_skia.log`), real-app baseline / bisection variants, plus `logs/README.md` indexing each file |
| `timelines/` | VM Service timeline dumps: `timeline_grad_impeller.json` (reproducer, aurora-like scenario) and gzipped real-app dumps for both renderers |
| `scripts/` | the capture/analysis tooling (`capture.dart` grabs a timeline over the VM Service; `repro_compare.py`, `analyze_grad.py`, `analyze_real.py`, `bisect_report.py`, `app_compare.py`) |
| `patches/` | the temporary instrumentation applied to the reporting app (frame-timing logger, auto entry into its simulated-data mode, feature bisection switches) |

Quick orientation, from the top-level `README.md`:

- Reproduce with `cd repro && flutter run -d linux --enable-impeller` and `… --no-enable-impeller`; one `[FT] <scenario> <build> <raster> <vsync> <totalSpan>` line per frame (ms).
- Scenario medians (raster, debug): solid colour 0.59 / 0.62 ms (0.96×, control), 9 rounded gradient panels **2.03 / 1.04 ms (1.95×)**, aurora-like **2.56 / 1.14 ms (2.24×)**.
- Reproducer timeline, Impeller, aurora-like scenario: `RenderPassGLES::EncodeCommandsInReactor` **2550 events over 102 frames → ~25 render passes per frame** for a scene containing ~9 gradient draws, and **no texture-upload events**, so a colour-ramp re-upload is not involved.

Still very much interested in the answers to the three questions in my previous comment — in particular whether issuing a render pass per blended draw is expected in the GL backend, and whether a PR that reduces the number of passes would be welcome.

