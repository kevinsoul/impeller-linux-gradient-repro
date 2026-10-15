# Log index

All logs are `flutter run` console captures (debug builds, Linux desktop, 2560×1440 physical).
`[FT] <scenario> <build> <raster> <vsyncOverhead> <totalSpan>` lines are emitted per frame
(ms, from `SchedulerBinding.addTimingsCallback`).

## Reproducer (standalone app in `../repro`)

| file | contents |
|---|---|
| `grad_impeller.log` | 5 gradient scenarios, Impeller (`--enable-impeller`) |
| `grad_skia.log` | same scenarios, Skia (`--no-enable-impeller`) |
| `grad_timeline.log` | Impeller, single scenario `grad_aurora_like` held for 45 s (source of `../timelines/timeline_grad_impeller.json`) |

## Reporting app (private), measured automatically in simulated-data mode

| file | contents |
|---|---|
| `app_autosim_impeller.log` | baseline, Impeller, 20 s |
| `app_autosim_skia.log` | baseline, Skia, 20 s |
| `bisect_imp_baseline.log` | all decorations enabled (reference) |
| `bisect_imp_no_glass.log` | glass-surface decorations disabled (gradient fill + border + highlight + shadow + ClipRRect) |
| `bisect_imp_no_aurora.log` | background (7 radial gradients + wash + grid) disabled |
| `bisect_imp_no_shadow.log` | `BoxShadow` only disabled |
| `bisect_imp_no_clip.log` | `ClipRRect` only disabled |
| `bisect_imp_no_gradient.log` | panel gradient fill only disabled |
| `bisect_imp_no_highlight.log` | top-highlight gradient overlay only disabled |
| `bisect_imp_no_blur.log` | `BackdropFilter` blur only disabled |
| `bisect_imp_no_chart.log` | history chart hidden |
| `bisect_imp_no_text.log` | table value text omitted |

Summaries:

```bash
python3 ../scripts/app_compare.py app_autosim_impeller.log app_autosim_skia.log
python3 ../scripts/bisect_report.py "baseline=bisect_imp_baseline.log" "no_glass=bisect_imp_no_glass.log" ...
```
