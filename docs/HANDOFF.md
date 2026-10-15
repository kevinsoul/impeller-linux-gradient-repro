# 交接文档：在新服务器上动手修 Impeller Linux GL 的渐变/pass 开销

- 上游 issue：**flutter/flutter#194433**（现象 → 归因 → 材料，共 3 条评论）
- 复现仓库（本仓库）：https://github.com/kevinsoul/impeller-linux-gradient-repro
- 应用仓库（private）：`kevinsoul/pressure-sensor-12x4`，分支 `exp/mask-8x2`，HEAD `fed1a01`（v2.21.2）

---

## 0. 结论链（一句话版）

经过 3 轮控变量实验，差距**不在图元种类**，而在 **Impeller Linux GL 后端对带混合的大面积渐变/填充逐绘制开渲染通道**：

```
真机 Impeller raster 11.87ms vs Skia 5.25ms（2.26x；同 20s 内 206 帧 vs 358 帧）
  └─ 关掉玻璃装饰 → 6.75ms（-44%，恢复 Skia 量级）
       └─ 其中「面板渐变填充 -19%」+「顶部高光渐变 -16%」= 每面板两层大渐变
            └─ 最小复现：9 个圆角渐变面板 2.03 vs 1.04ms（1.95x）
                         极光式渐变组合   2.56 vs 1.14ms（2.24x）
                         纯色对照         0.59 vs 0.62ms（0.96x，持平）
                 └─ 引擎 timeline：每帧 ~25 个 RenderPassGLES::EncodeCommandsInReactor
                    （场景仅 ~9 次渐变绘制），且零纹理上传事件 → 不是色带重传缓存问题
```

---

## 1. 目标与验收标准

**目标**：在 Impeller Linux GL 后端减少每帧渲染通道数 / 消除渐变路径的多余 pass，使渐变密集场景的性能接近 Skia。

**验收（全部用本仓库的自动化测量，无需人工操作）**：

| # | 项目 | 现状 | 目标 |
|---|---|---|---|
| a | `repro` `grad_aurora_like` raster 中位 | 2.56 ms | ≤ 1.4 ms（Skia 1.14 的 1.2× 以内） |
| b | `repro` `grad_linear_panels` raster 中位 | 2.03 ms | ≤ 1.3 ms（Skia 1.04 的 1.25× 以内） |
| c | `repro` `grad_solid_full`（对照） | 0.59 ms | 不退化（≤ 0.7 ms） |
| d | 真机 autosim raster 中位（需恢复补丁，见 §7） | 11.87 ms | ≤ 7 ms；帧产出 206 → ≥ 340 / 20 s |
| e | 正确性 | — | impeller 相关单测通过；应用仓库全量测试 241 通过 / 1 跳过 |

> 只改渲染管线时，应用仓库的 241 个测试是回归底线（协议/状态机/UI 数据层）。

---

## 2. 新服务器准备

**必需工具**：`git`、`python3`、`curl`、`unzip`、`pkg-config`、Chromium `depot_tools`（内含 `gclient`，需加到 `PATH` 最前）、`ninja`（depot_tools 附带）。
**不需要**单独安装 Dart / Android SDK（`gclient sync` 会拉取）。

**硬件建议**：磁盘预留 **100 GB+**（引擎 checkout + `out/` 构建产物很大，`out/` 务必排除在任何备份/同步脚本之外）；内存 **32 GB+**（优化版链接阶段很吃内存，否则一律加 `--no-lto`）。

**重要事实**：**引擎源码自 2024 年底已并入 `flutter/flutter` 单仓**，不再单独 clone `flutter/engine`。文档以官方为准：

- `docs/engine/contributing/Setting-up-the-Engine-development-environment.md`
- `docs/engine/contributing/Compiling-the-engine.md`
- 引擎工具 `et`：`engine/src/flutter/tools/engine_tool`（官方推荐用它替代手工 gn/ninja）

---

## 3. 引擎环境搭建（要点，细节以官方文档为准）

```bash
# 0) depot_tools 放到 PATH 最前
export PATH="$HOME/depot_tools:$PATH"

# 1) 克隆 flutter/flutter（约定：origin=自己的 fork，upstream=flutter/flutter）
git clone git@github.com:<you>/flutter.git ~/dev/flutter
cd ~/dev/flutter

# 2) gclient 引导：把 engine/scripts/standard.gclient 复制到仓库根目录为 .gclient
cp engine/scripts/standard.gclient .gclient

# 3) 拉取依赖（首次耗时长）
gclient sync -D

# 4) 构建 host（Linux 桌面用 host 目标即可）
cd engine/src
flutter/tools/gn --unoptimized --runtime-mode=debug      # → out/host_debug_unopt
ninja -C out/host_debug_unopt

# 性能量化建议再建一个 release（无 LTO）
flutter/tools/gn --runtime-mode=release --no-lto          # → out/host_release
ninja -C out/host_release
```

更新引擎代码：`git fetch upstream main && git rebase upstream/main && gclient sync -D`（注意 `docs` 里写的是 `master`，以仓库当前默认分支为准）。

---

## 4. 用本地引擎跑我们的东西

本机 **Flutter 3.47.7** 已确认 `flutter run` 支持（`flutter run --help --verbose`）：

```bash
# 最小复现（在 repro/ 目录）
flutter run -d linux --enable-impeller \
  --local-engine-src-path=$HOME/dev/flutter/engine/src \
  --local-engine=host_debug_unopt

# 真机（在 pressure 仓库，先按 §7 恢复补丁）
PRESSURE_FRAME_TIMINGS=1 PRESSURE_AUTOSIM=60 PRESSURE_AUTOSIM_SECONDS=20 \
flutter run -d linux --enable-impeller \
  --local-engine-src-path=$HOME/dev/flutter/engine/src \
  --local-engine=host_debug_unopt
```

- 最小复现工程默认就是 Impeller（模板默认），`--enable-impeller` 只是显式声明。
- 应用仓库的 runner 已回退 Skia，**测 Impeller 必须带 `--enable-impeller`**（引擎环境开关会覆盖 runner 设置，已验证）。
- `--local-engine` 会同时影响 AOT/JIT 产物选择；测 release 行为时用 `--local-engine=host_release`。

---

## 5. 已确认的事实（不要重复劳动）

**真机（应用，20 s 模拟采集稳态，debug）**

| 渲染器 | 帧数 | build 中位 | raster 中位 | raster p90 | vsync 中位 | totalSpan 中位 |
|---|---|---|---|---|---|---|
| Impeller | 206 | 23.70 | **11.87** | 14.81 | 9.23 | 45.40 |
| Skia | 358 | 13.20 | **5.25** | 6.32 | 2.06 | 20.79 |

**特征二分（Impeller raster 中位，基线 12.02ms）**

| 关闭项 | 结果 | 变化 |
|---|---|---|
| 玻璃装饰（渐变+描边+高光+阴影+裁剪） | 6.75 ms（351 帧） | **−44 %** |
| 极光背景（7 径向渐变 + wash + 网格） | 9.71 ms（347 帧） | −19 % |
| 阴影 / ClipRRect / BackdropFilter | 11.66 / 11.11 / 10.95 ms | −3 % / −8 % / −9 % |
| 渐变填充 / 高光渐变 | 9.75 / 10.14 ms | **−19 % / −16 %** |
| 图表 / 表格文本 | 12.20 / 12.23 ms | ~0 % |

**最小复现（debug，raster 中位）**

| 场景 | Impeller | Skia | 倍率 |
|---|---|---|---|
| 全屏纯色（对照） | 0.59 | 0.62 | 0.96x |
| 全屏 2 段线性渐变 | 1.06 | 0.81 | 1.30x |
| 9 个圆角面板（线性渐变+描边） | 2.03 | 1.04 | 1.95x |
| 全屏 3 段径向渐变 | 1.01 | 0.80 | 1.26x |
| 极光式（7 径向 + wash + 网格） | 2.56 | 1.14 | 2.24x |

**引擎 timeline**

- 复现工程 `grad_aurora_like`：102 帧 / 1.8 s，`GPURasterizer::Draw` 3.12 ms/帧；`RenderPassGLES::EncodeCommandsInReactor` **2550 次 → 25 pass/帧**（编码本身仅 ~0.5 ms/帧）；**零纹理上传事件**。
- 真机：`ReactorGLES::React`/`FlushOps` **3.83 ms/帧**（约 **153** 个 `ReactorGLES::Operation`/帧）、`FlutterCompositorPresentLayers` **3.37 ms/帧**（Skia 同项 0.50 ms）；Skia 侧 `EmbedderExternalView::Render` 3.12 ms/帧。

---

## 6. 建议的源码调查入口（先 grep 再下结论）

在 `engine/src/flutter` 下：

```bash
rg -n "EncodeCommandsInReactor" impeller/                     # 我们的 pass 计量点
rg -n "CreateRenderPass|GetRenderPass" impeller/renderer impeller/entity | head -50
rg -n "class GradientContents|ColorSourceContents" impeller/entity/contents
rg -n "RenderPassGLES|CommandBufferGLES|ReactorGLES" impeller/renderer/backend/gles
rg -n "EntityPass::" impeller/entity/entity_pass.cc | head -40   # 分层/合并逻辑所在
```

**待验证假设（按优先级）**

| 假设 | 说明 | 验证方式 |
|---|---|---|
| **H1 每绘制独立 pass** | 带混合的 Contents/Entity 各自成 pass，GL 后端每 pass 反复读写整屏 FBO → 带宽瓶颈（核显尤甚） | 在 `CreateRenderPass` 处加计数器，比较改动前后「每帧 pass 数」；同时看 repro raster 中位 |
| H2 渐变未走廉价路径 | 渐变走 runtime-effect/着色器路径，而非常见 blend 快路径 | 看 `GradientContents`/`ColorSourceContents` 的渲染实现与着色器分支 |
| H3 saveLayer 额外 offscreen | 真机 `no_clip` 仅 −8 %，`no_blur` −9 % → 不是主因，但可顺带核对 | 看 `saveLayer`/`EntityPass` 嵌套处的目标切换 |

**量化工具**（本仓库 `scripts/`）：`capture.dart` 通过 VM Service 抓 timeline；`analyze_grad.py` 统计 pass/纹理事件；`repro_compare.py` 出 Impeller/Skia 对照表。

---

## 7. 真机回归流程（需要主仓库 + 补丁）

```bash
cd pressure-sensor-12x4                  # private 仓库，分支 exp/mask-8x2
git apply <本仓库>/patches/forensic_instrumentation.patch

# 基线
PRESSURE_FRAME_TIMINGS=1 PRESSURE_AUTOSIM=60 PRESSURE_AUTOSIM_SECONDS=20 \
PRESSURE_BISECT=baseline flutter run -d linux --enable-impeller [--local-engine...]

# 分析
python3 <本仓库>/scripts/app_compare.py app_autosim_impeller.log app_autosim_skia.log

# 还原（补丁绝不提交）
git checkout -- .
```

补丁包含三样东西，均通过环境变量启用：

- `PRESSURE_FRAME_TIMINGS=1` —— 逐帧打印 `FrameTiming`
- `PRESSURE_AUTOSIM=<fps>`（+`PRESSURE_AUTOSIM_SECONDS=<n>`）—— 自动进入「模拟数据 + 采集」，n 秒后自动退出（无需人工 hover）
- `PRESSURE_BISECT=no_glass|no_aurora|no_gradient|no_highlight|no_shadow|no_clip|no_blur|no_chart|no_text` —— 特征二分开关

---

## 8. 备选方案（若引擎改动代价过大）

**工具层 PR**：`flutter_tools` 把 Linux 桌面默认渲染器改回 Skia（临时止血），用 §5 的真机数据作依据。改动小、可本地跑 `flutter_tools` 测试，但上游立场是推进 Impeller，可能被要求先修根因。

---

## 9. 上游沟通状态

`#194433` 已发 3 条评论：① 现象与 A/B 复现 ② 归因 + 最小复现 + 25 pass/帧 ③ 材料仓库链接。

**已向上游提问（等回复）**：

1. GL 后端「逐（混合）绘制开渲染通道」是否符合预期？相邻可共享 pass 的绘制目前有批处理吗？路线图上有相关计划吗？
2. 依据该复现（纯色持平、渐变面板 1.95x、渐变色斑 2.24x），填充率/pass 开销是否就是被认可的原因？是否有已知 issue/优化项应当改follow？
3. 若「减少 pass 数」的 PR 受欢迎，我们愿意做 —— 需要先搭引擎环境，希望得到 `impeller` 侧的入手点指引。

新服务器上先执行：`gh issue view 194433 --repo flutter/flutter --comments`

---

## 10. 材料与命令速查

| 路径 | 内容 |
|---|---|
| `repro/` | 最小复现工程（5 场景，Ticker 驱动，无需鼠标操作，跑完自动退出） |
| `logs/` | 全部逐帧 `FrameTiming` 日志（`logs/README.md` 有逐文件索引） |
| `timelines/` | VM timeline（复现工程 5.4 MB；真机两个渲染器 gzip） |
| `scripts/` | 抓取与分析工具；`scripts/vm_capture/` 是可运行的 Dart 包（timeline 抓取） |
| `patches/` | 主仓库取证埋点补丁 |
| `docs/HANDOFF.md` | 本文档 |
| `docs/issue-updates.md` | 已发到上游的 3 条评论原文 |

```bash
# 复现工程对照（无需人工操作，各约 3–4 分钟）
cd repro
script -qec "flutter run -d linux --enable-impeller"    /tmp/grad_impeller.log
script -qec "flutter run -d linux --no-enable-impeller" /tmp/grad_skia.log
python3 ../scripts/repro_compare.py /tmp/grad_impeller.log /tmp/grad_skia.log

# 单场景 + 抓 timeline
REPRO_ONLY=grad_aurora_like REPRO_SECONDS=45 flutter run -d linux --enable-impeller
cd ../scripts/vm_capture && dart pub get
dart run bin/capture.dart "ws://127.0.0.1:<port>/<token>/ws" 12 /tmp/tl.json
python3 ../analyze_grad.py /tmp/tl.json
```
