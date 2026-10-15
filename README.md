# Impeller Linux (GL): gradient-heavy scenes ~2× slower than Skia — reproducer & measurements

Material for **[flutter/flutter#194433](https://github.com/flutter/flutter/issues/194433)**
(`[Linux] Impeller (default since 3.47) causes jank on pointer-driven repaints on AMD radeonsi/Mesa (Wayland)`).

## Environment

- Flutter 3.47.7 stable (engine `deb287481e`), Dart 3.13.5, snap install
- Ubuntu 24.04.3 LTS, GNOME on Wayland, kernel 6.8.0-146-generic
- GPU: AMD Radeon Vega 8 (Picasso), Mesa 25.2.8 (`radeonsi`, ACO), OpenGL 4.6
- Window 1280×720 logical @2× = 2560×1440 physical, debug builds
- Renderer confirmed from the engine log line
  `Using the Impeller rendering backend (OpenGLESSDF)` (absent under Skia)

## Layout

| path | contents |
|---|---|
| `repro/` | Standalone Flutter app with 5 scenarios; repaints every frame from a `Ticker`, so **no mouse input is required** |
| `logs/` | Per-frame `FrameTiming` logs — see `logs/README.md` |
| `timelines/` | VM Service timeline dumps (B/E events paired on the raster/UI threads); `.json.gz` are gzipped |
| `scripts/` | Capture + analysis tooling used for the measurements (`scripts/vm_capture/` is a runnable Dart package) |
| `patches/` | Temporary instrumentation applied to the *reporting app* (frame-timing logger, auto entry into its simulated-data mode, feature bisection flags) |
| `docs/HANDOFF.md` | **Hand-over notes (Chinese): engine build steps, local-engine flags, source-entry grep recipes, hypotheses, acceptance criteria for a fix** |
| `docs/issue-updates.md` | The three comments posted to the upstream issue |

## Running the reproducer

```bash
cd repro
flutter run -d linux --enable-impeller      # Impeller
flutter run -d linux --no-enable-impeller   # Skia (control)
```

Each scenario runs for 5 s and prints one line per frame:

```
[FT] <scenario> <build_ms> <raster_ms> <vsyncOverhead_ms> <totalSpan_ms>
```

The app exits by itself after the last scenario, so both renderers can be measured back-to-back without interaction.
For timeline capture, run a single scenario longer:

```bash
REPRO_ONLY=grad_aurora_like REPRO_SECONDS=45 flutter run -d linux --enable-impeller
# then grab a timeline over the VM Service:
cd scripts/vm_capture && dart pub get
dart run bin/capture.dart "ws://127.0.0.1:<port>/<token>/ws" 12 timeline.json
```

Scenarios: `grad_solid_full` (control), `grad_linear_full`, `grad_linear_panels`
(9 rounded panels, each with a 2-stop linear gradient + border), `grad_radial_full`,
`grad_aurora_like` (7 radial gradient blobs with radius ≈ 0.8–1.1× shortestSide, one
full-screen linear "wash" gradient, ~46 grid lines — the composition used by the reporting app's background).

## Results — raster thread, median per scenario (debug)

| scenario | Impeller | Skia | ratio |
|---|---|---|---|
| full-screen solid colour (control) | 0.59 ms | 0.62 ms | 0.96× |
| full-screen 2-stop linear gradient | 1.06 ms | 0.81 ms | 1.30× |
| 9 rounded panels, linear gradient + border | **2.03 ms** | **1.04 ms** | **1.95×** |
| full-screen 3-stop radial gradient | 1.01 ms | 0.80 ms | 1.26× |
| `grad_aurora_like` | **2.56 ms** | **1.14 ms** | **2.24×** |

Raw numbers: `logs/grad_impeller.log` and `logs/grad_skia.log`
(reproduce with `python3 scripts/repro_compare.py logs/grad_impeller.log logs/grad_skia.log`).

## Engine timeline of the reproducer (Impeller, `grad_aurora_like`)

`python3 scripts/analyze_grad.py timelines/timeline_grad_impeller.json`:

```
timeline 1.8 s, 102 raster frames
GPURasterizer::Draw                          102 (1/frame)   318.4 ms   3.12 ms/frame
└ Rasterizer::DrawToSurfaces                 102             315.5 ms   3.09 ms/frame
  └ RenderPassGLES::EncodeCommandsInReactor  2550            → 25 render passes per frame
     (≈0.02 ms each, so only ~0.5 ms/frame of encoder CPU time)
```

- The scene contains ~9 gradient draws plus grid lines, yet the GL backend records **~25 render passes per frame**.
- **No texture-upload events** appear on the raster thread in this scene, so a "gradient colour ramp re-uploaded every frame"
  cache problem is **not** the cause.

Real-app timelines (gzipped) show the same shape at scale: `ReactorGLES::React`/`FlushOps` ≈ 3.83 ms/frame
(≈153 `ReactorGLES::Operation` per frame) and `FlutterCompositorPresentLayers` ≈ 3.37 ms/frame, where the same
event under Skia is ≈ 0.50 ms (`Timeline_real_*`; analysis: `python3 scripts/analyze_real.py timelines/timeline_real_impeller.json timelines/timeline_real_skia.json`).

## Real-app measurements (for context)

The reporting app was measured with a temporary flag that enters its built-in simulated-data mode
(60 fps source, UI refresh throttled to ~100 ms), 20 s of steady state per renderer, plus a feature bisection
that disables individual decorations. Numbers are quoted in the issue comment; the logs are
`logs/app_autosim_*.log` (baseline) and `logs/bisect_imp_*.log` (bisection variants), summarised by
`scripts/bisect_report.py` and `scripts/app_compare.py`.

## Hand-over notes

Everything needed to continue this work — engine build steps (engine sources now live inside the
`flutter/flutter` monorepo), the `--local-engine*` flags verified for Flutter 3.47.7, source-navigation
grep recipes for `impeller`, the remaining hypotheses and the acceptance criteria for a fix — is recorded in
[`docs/HANDOFF.md`](docs/HANDOFF.md) (Chinese). The three comments posted upstream are in
[`docs/issue-updates.md`](docs/issue-updates.md).

Upstream questions still open (see the third comment): whether one render pass per blended draw is expected
in the GL backend, whether batching is planned, and whether a pass-reducing PR would be welcome.
