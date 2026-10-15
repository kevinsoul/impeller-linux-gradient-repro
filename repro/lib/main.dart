// Impeller(Linux/GL) 光栅开销隔离工程 —— 上游 issue flutter/flutter#194433 的最小复现
//
// 每个场景由 Ticker 驱动强制每帧重绘，并在每帧打印 FrameTiming（scenario/build/raster/vsync/total，
// 单位 ms）。8 个场景全部跑完后自动退出，因此无需人工 hover：
//
//   flutter run -d linux --enable-impeller     # Impeller
//   flutter run -d linux --no-enable-impeller  # Skia（对照）
//
// 对比两份输出的 [FT] 行即可得到「每帧光栅耗时」矩阵。
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 当前场景名，供 FrameTiming 回调打标
String currentScenario = 'warmup';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SchedulerBinding.instance.addTimingsCallback((List<FrameTiming> timings) {
    for (final t in timings) {
      final b = t.buildDuration.inMicroseconds / 1000.0;
      final r = t.rasterDuration.inMicroseconds / 1000.0;
      final v = t.vsyncOverhead.inMicroseconds / 1000.0;
      final s = t.totalSpan.inMicroseconds / 1000.0;
      stdout.writeln('[FT] $currentScenario $b $r $v $s');
    }
  });
  runApp(const ReproApp());
}

const List<String> kScenarios = <String>[
  'grad_solid_full', // 对照：全屏纯色
  'grad_linear_full', // 全屏 2 段线性渐变
  'grad_linear_panels', // 10 个面板（圆角+线性渐变+描边）
  'grad_radial_full', // 全屏径向渐变
  'grad_aurora_like', // 应用的极光式渐变组合（7 径向 + wash + 网格）
];

class ReproApp extends StatelessWidget {
  const ReproApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ScenarioRunner(),
    );
  }
}

class ScenarioRunner extends StatefulWidget {
  const ScenarioRunner({super.key});

  @override
  State<ScenarioRunner> createState() => _ScenarioRunnerState();
}

class _ScenarioRunnerState extends State<ScenarioRunner>
    with SingleTickerProviderStateMixin {
  /// REPRO_ONLY=<场景名> 只跑该场景；REPRO_SECONDS=<n> 每场景时长（默认 5s）
  static final List<String> _active = () {
    final only = Platform.environment['REPRO_ONLY'] ?? '';
    if (only.isEmpty) return kScenarios;
    return kScenarios.where((s) => s == only).toList();
  }();

  static final Duration _perScenario = Duration(
    seconds: int.tryParse(Platform.environment['REPRO_SECONDS'] ?? '') ?? 5,
  );

  late final Ticker _ticker;
  Timer? _timer;
  int _index = 0;
  double _t = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      setState(() => _t = elapsed.inMicroseconds / 1e6);
    })..start();
    _startScenario();
  }

  void _startScenario() {
    if (_index >= _active.length) {
      stdout.writeln('[REPRO] DONE scenarios=${_active.length}');
      Timer(const Duration(milliseconds: 500), () => exit(0));
      return;
    }
    currentScenario = _active[_index];
    stdout.writeln('[SCENARIO] start ${_active[_index]}');
    _timer = Timer(_perScenario, () {
      stdout.writeln('[SCENARIO] end ${_active[_index]}');
      setState(() => _index++);
      _startScenario();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = _index < _active.length ? _active[_index] : 'done';
    return Scaffold(
      body: SizedBox.expand(
        child: RepaintBoundary(child: _buildScenario(name, _t)),
      ),
    );
  }

  Widget _buildScenario(String name, double t) {
    switch (name) {
      case 'baseline_solid':
        return CustomPaint(painter: SolidPainter(t), size: Size.infinite);
      case 'grid_48cells':
        return CustomPaint(painter: GridPainter(t), size: Size.infinite);
      case 'rects_2000':
        return CustomPaint(painter: ManyRectsPainter(t), size: Size.infinite);
      case 'blur_8panels':
        return BlurPanels(count: 8, t: t);
      case 'blur_1full':
        return BlurPanels(count: 1, t: t);
      case 'savelayer_20':
        return CustomPaint(painter: SaveLayerPainter(t), size: Size.infinite);
      case 'text_400':
        return CustomPaint(painter: TextPainterPainter(t), size: Size.infinite);
      case 'combined':
        return const CombinedScene();
      // ---- 渐变专项 ----
      case 'grad_solid_full':
        return CustomPaint(painter: SolidPainter(t), size: Size.infinite);
      case 'grad_linear_full':
        return CustomPaint(painter: GradFullPainter(t, radial: false), size: Size.infinite);
      case 'grad_linear_panels':
        return GradPanelsScene(t: t);
      case 'grad_radial_full':
        return CustomPaint(painter: GradFullPainter(t, radial: true), size: Size.infinite);
      case 'grad_aurora_like':
        return CustomPaint(painter: AppAuroraPainter(t), size: Size.infinite);
      case 'aurora_only':
        return CustomPaint(painter: AppAuroraPainter(t), size: Size.infinite);
      case 'shadows_22':
        return Shadows22Scene(t: t);
      case 'pseudo_glass_22':
        return PseudoGlass22Scene(t: t);
      case 'app_like':
        return AppLikeScene(t: t);
      default:
        return const ColoredBox(color: Colors.black);
    }
  }
}

/// 动画底图：给 blur 场景提供被模糊内容
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({super.key, required this.t});

  final double t;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _AuroraPainter(t), size: Size.infinite);
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0B1020));
    for (var i = 0; i < 6; i++) {
      final phase = t * 0.6 + i;
      final center = Offset(
        size.width * (0.5 + 0.42 * math.sin(phase)),
        size.height * (0.5 + 0.42 * math.cos(phase * 1.3)),
      );
      final paint = Paint()
        ..shader = ui.Gradient.radial(center, size.shortestSide * 0.45, <Color>[
          Color.fromARGB(150, 40 + i * 30, 120, 255 - i * 25),
          const Color(0x00000000),
        ]);
      canvas.drawRect(Offset.zero & size, paint);
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter oldDelegate) => oldDelegate.t != t;
}

/// 场景 1：单块全屏纯色
class SolidPainter extends CustomPainter {
  SolidPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Color.lerp(const Color(0xFF123456), const Color(0xFF654321), (math.sin(t) + 1) / 2)!,
    );
  }

  @override
  bool shouldRepaint(SolidPainter oldDelegate) => true;
}

/// 场景 2：12x4 单元格 + 网格线
class GridPainter extends CustomPainter {
  GridPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    const cols = 4;
    const rows = 12;
    final cellW = size.width / cols;
    final cellH = size.height / rows;
    final gridPaint = Paint()
      ..color = const Color(0x33FFFFFF)
      ..strokeWidth = 1;
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final v = (math.sin(t * 1.7 + r * 0.4 + c) + 1) / 2;
        final rect = Rect.fromLTWH(c * cellW + 1, r * cellH + 1, cellW - 2, cellH - 2);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(4)),
          Paint()..color = Color.lerp(const Color(0xFF102040), const Color(0xFFFF5533), v)!,
        );
        final inner = rect.deflate(6 * v);
        if (inner.width > 2 && inner.height > 2) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(inner, const Radius.circular(3)),
            Paint()..color = const Color(0x66FFFFFF),
          );
        }
      }
    }
    for (var c = 0; c <= cols; c++) {
      canvas.drawLine(Offset(c * cellW, 0), Offset(c * cellW, size.height), gridPaint);
    }
    for (var r = 0; r <= rows; r++) {
      canvas.drawLine(Offset(0, r * cellH), Offset(size.width, r * cellH), gridPaint);
    }
  }

  @override
  bool shouldRepaint(GridPainter oldDelegate) => true;
}

/// 场景 3：2000 个小矩形
class ManyRectsPainter extends CustomPainter {
  ManyRectsPainter(this.t);

  final double t;

  /// 预生成，避免每帧的 Dart 侧随机数开销污染测量
  static final List<Offset> _norm = () {
    final rnd = math.Random(7);
    return List<Offset>.generate(2000, (_) => Offset(rnd.nextDouble(), rnd.nextDouble()));
  }();

  @override
  void paint(Canvas canvas, Size size) {
    final positions = <Offset>[
      for (final n in _norm) Offset(n.dx * size.width, n.dy * size.height),
    ];
    final shift = 6 * math.sin(t * 2);
    for (var i = 0; i < positions.length; i++) {
      final p = positions[i] + Offset(shift, shift);
      canvas.drawRect(
        Rect.fromLTWH(p.dx, p.dy, 6, 6),
        Paint()..color = Color.fromARGB(255, 40 + (i % 200), 90, 200 - (i % 150)),
      );
    }
  }

  @override
  bool shouldRepaint(ManyRectsPainter oldDelegate) => true;
}

/// 场景 4/5：N 块 backdrop blur 面板
class BlurPanels extends StatelessWidget {
  const BlurPanels({super.key, required this.count, required this.t});

  final int count;
  final double t;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        AuroraBackground(t: t),
        for (var i = 0; i < count; i++)
          Positioned(
            left: 40.0 + i * 24,
            top: 40.0 + i * 18,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(
                  width: count == 1 ? 900 : 320,
                  height: count == 1 ? 560 : 200,
                  decoration: BoxDecoration(
                    color: const Color(0x22FFFFFF),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0x44FFFFFF)),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 场景 6：20 处 saveLayer + blur
class SaveLayerPainter extends CustomPainter {
  SaveLayerPainter(this.t);

  final double t;

  /// 预生成，避免每帧随机数开销
  static final List<Offset> _norm = () {
    final rnd = math.Random(11);
    return List<Offset>.generate(20, (_) => Offset(rnd.nextDouble(), rnd.nextDouble()));
  }();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF101828));
    for (var i = 0; i < 20; i++) {
      final rect = Rect.fromLTWH(
        _norm[i].dx * (size.width - 160),
        10 + _norm[i].dy * (size.height - 120) + 4 * math.sin(t * 2 + i),
        140,
        90,
      );
      canvas.saveLayer(
        rect,
        Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(12)),
        Paint()..color = Color.fromARGB(200, 60 + i * 8, 120, 255 - i * 9),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(SaveLayerPainter oldDelegate) => true;
}

/// 场景 7：400 段预排版文本（避免把排版开销算进光栅）
class TextPainterPainter extends CustomPainter {
  TextPainterPainter(this.t);

  final double t;

  static final List<TextPainter> _cache = <TextPainter>[];

  static List<TextPainter> _painters() {
    if (_cache.isEmpty) {
      for (var i = 0; i < 400; i++) {
        _cache.add(
          TextPainter(
            text: TextSpan(
              text: '单元 ${i % 48}  压力 ${(i % 100) / 10}  MPa',
              style: const TextStyle(fontSize: 13, color: Color(0xFFDCE7FF)),
            ),
            textDirection: TextDirection.ltr,
          )..layout(),
        );
      }
    }
    return _cache;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final painters = _painters();
    const cols = 4;
    final cellW = size.width / cols;
    const rowH = 18.0;
    final shift = 3 * math.sin(t * 1.5);
    for (var i = 0; i < painters.length; i++) {
      final c = i % cols;
      final r = (i ~/ cols) % 40;
      painters[i].paint(canvas, Offset(c * cellW + 8 + shift, 8 + r * rowH));
    }
  }

  @override
  bool shouldRepaint(TextPainterPainter oldDelegate) => true;
}

/// 场景 8：玻璃面板 + 表格 + 折线图（≈ 本项目实时界面）
class CombinedScene extends StatefulWidget {
  const CombinedScene({super.key});

  @override
  State<CombinedScene> createState() => _CombinedSceneState();
}

class _CombinedSceneState extends State<CombinedScene>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _t = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      setState(() => _t = elapsed.inMicroseconds / 1e6);
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        AuroraBackground(t: _t),
        Row(
          children: <Widget>[
            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                    child: Container(
                      color: const Color(0x1AFFFFFF),
                      child: CustomPaint(painter: GridPainter(_t), size: Size.infinite),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              flex: 1,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                    child: Container(
                      color: const Color(0x1AFFFFFF),
                      child: CustomPaint(painter: ChartPainter(_t), size: Size.infinite),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 折线图（≈ inline_history_chart）
class ChartPainter extends CustomPainter {
  ChartPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = const Color(0xFF66E0FF)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (var s = 0; s < 6; s++) {
      final path = Path();
      for (var x = 0.0; x <= size.width; x += 4) {
        final y = size.height / 2 +
            math.sin((x / 40) + t * 2 + s) * size.height * 0.35 +
            math.sin((x / 11) + s) * 6;
        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, line..color = Color.lerp(const Color(0xFF66E0FF), const Color(0xFFFFAA44), s / 6)!);
    }
  }

  @override
  bool shouldRepaint(ChartPainter oldDelegate) => true;
}

// ============================================================================
// 第二轮场景：复刻真实应用（pressure）的绘制特征
// 依据：lib/ui/components/aurora_background.dart（7 径向色斑 + wash + 网格）
//       lib/ui/theme/glass.dart（伪玻璃：渐变填充/描边/高光/BoxShadow blur26 offset(0,8)）
// ============================================================================

/// 精确复刻应用的极光背景
class AppAuroraPainter extends CustomPainter {
  AppAuroraPainter(this.t);

  final double t;

  void _blob(Canvas canvas, Offset center, double radius, Color color, double opacity) {
    if (radius <= 0) return;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..shader = RadialGradient(
        stops: const [0.0, 0.5, 1.0],
        colors: <Color>[
          color.withValues(alpha: opacity),
          color.withValues(alpha: opacity * 0.55),
          color.withValues(alpha: 0),
        ],
      ).createShader(rect);
    canvas.drawCircle(center, radius, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    const primary = Color(0xFF5B7CFA);
    const secondary = Color(0xFF9B5BFA);
    const success = Color(0xFF3BD6A0);
    final shortest = size.shortestSide;

    _blob(canvas, Offset(size.width * 0.08, size.height * 0.02), shortest * 1.05, primary, 0.85);
    _blob(canvas, Offset(size.width * 1.02, size.height * 0.12), shortest * 0.95, secondary, 0.80);
    _blob(canvas, Offset(size.width * 0.0, size.height * 1.0), shortest * 0.95, secondary, 0.62);
    _blob(canvas, Offset(size.width * 0.55, size.height * 1.08), shortest * 1.1, success, 0.60);
    _blob(canvas, Offset(size.width * 0.45, size.height * 0.42), shortest * 0.85, secondary, 0.48);
    _blob(canvas, Offset(size.width * 0.72, size.height * 0.55), shortest * 0.8, primary, 0.48);
    _blob(canvas, Offset(size.width * 0.30, size.height * 0.75), shortest * 0.8, success, 0.38);

    final wash = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[Color(0x1A5B7CFA), Color(0x149B5BFA)],
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, wash);

    final gridPaint = Paint()
      ..color = const Color(0x09FFFFFF)
      ..strokeWidth = 1;
    const step = 56.0;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  @override
  bool shouldRepaint(AppAuroraPainter oldDelegate) => true;
}

/// 伪玻璃面板（GlassSurface(blur:false) 的等价绘制）
class PseudoGlass extends StatelessWidget {
  const PseudoGlass({super.key, required this.child, this.radius = 20, this.glowOpacity = 0});

  final Widget child;
  final double radius;
  final double glowOpacity;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    final content = Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0x2EFFFFFF), Color(0x0FFFFFFF)],
        ),
        borderRadius: r,
        border: Border.all(color: const Color(0x4DFFFFFF), width: 1),
      ),
      child: Stack(
        children: <Widget>[
          child,
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: r,
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[Color(0x66FFFFFF), Color(0x00FFFFFF)],
                    stops: <double>[0.0, 0.14],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    return Container(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: <BoxShadow>[
          BoxShadow(color: const Color(0x33000000), blurRadius: 26, offset: const Offset(0, 8)),
        ],
      ),
      child: ClipRRect(borderRadius: r, child: content),
    );
  }
}

/// 22 个 RRect + BoxShadow（隔离阴影开销）
class Shadows22Scene extends StatelessWidget {
  const Shadows22Scene({super.key, required this.t});

  final double t;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        const ColoredBox(color: Color(0xFF1E1E40)),
        for (var i = 0; i < 22; i++)
          Positioned(
            left: 12.0 + (i % 6) * 200,
            top: 8.0 + (i ~/ 6) * 130 + 4 * math.sin(t * 2 + i),
            child: Container(
              width: 190,
              height: 120,
              decoration: BoxDecoration(
                color: const Color(0x33222244),
                borderRadius: BorderRadius.circular(20),
                boxShadow: <BoxShadow>[
                  BoxShadow(color: const Color(0x33000000), blurRadius: 26, offset: const Offset(0, 8)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 22 个伪玻璃面板叠在极光背景上
class PseudoGlass22Scene extends StatelessWidget {
  const PseudoGlass22Scene({super.key, required this.t});

  final double t;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        CustomPaint(painter: AppAuroraPainter(t), size: Size.infinite),
        for (var i = 0; i < 22; i++)
          Positioned(
            left: 12.0 + (i % 6) * 200,
            top: 8.0 + (i ~/ 6) * 130 + 4 * math.sin(t * 2 + i),
            child: const SizedBox(
              width: 190,
              height: 120,
              child: PseudoGlass(child: SizedBox.expand()),
            ),
          ),
      ],
    );
  }
}

/// 48 格表格 + 数值文本（复刻应用的 12x4 数据表）
class TableWithTextPainter extends CustomPainter {
  TableWithTextPainter(this.t);

  final double t;

  static final List<TextPainter> _labels = <TextPainter>[];

  static List<TextPainter> _painters() {
    if (_labels.isEmpty) {
      for (var i = 0; i < 48; i++) {
        _labels.add(
          TextPainter(
            text: TextSpan(
              text: '${(i * 7 % 50) / 10}',
              style: const TextStyle(fontSize: 13, color: Color(0xFFE6ECFF)),
            ),
            textDirection: TextDirection.ltr,
          )..layout(),
        );
      }
    }
    return _labels;
  }

  @override
  void paint(Canvas canvas, Size size) {
    const cols = 4;
    const rows = 12;
    final cw = size.width / cols;
    final ch = size.height / rows;
    final painters = _painters();
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final v = (math.sin(t * 1.7 + r * 0.4 + c) + 1) / 2;
        final rect = Rect.fromLTWH(c * cw + 2, r * ch + 2, cw - 4, ch - 4);
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(6)),
          Paint()..color = Color.lerp(const Color(0x002C2C54), const Color(0xCC5B7CFA), v)!,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(6)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = const Color(0x33FFFFFF),
        );
        final tp = painters[r * cols + c];
        tp.paint(canvas, Offset(rect.center.dx - tp.width / 2, rect.center.dy - tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(TableWithTextPainter oldDelegate) => true;
}

/// 应用界面近似：极光 + 标题栏 + 数据表（含文本）+ 侧栏（含图表）+ 状态栏
class AppLikeScene extends StatelessWidget {
  const AppLikeScene({super.key, required this.t});

  final double t;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        CustomPaint(painter: AppAuroraPainter(t), size: Size.infinite),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            children: <Widget>[
              // 标题栏
              const SizedBox(
                height: 56,
                child: PseudoGlass(child: Center(child: SizedBox(width: 200, height: 20))),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Row(
                  children: <Widget>[
                    // 数据表面板（表格 + 文本）
                    Expanded(
                      flex: 3,
                      child: PseudoGlass(
                        child: CustomPaint(painter: TableWithTextPainter(t), size: Size.infinite),
                      ),
                    ),
                    const SizedBox(width: 10),
                    // 右侧控制面板（含折线图）
                    Expanded(
                      child: PseudoGlass(
                        child: CustomPaint(painter: ChartPainter(t), size: Size.infinite),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              // 状态栏
              const SizedBox(
                height: 40,
                child: PseudoGlass(child: Center(child: SizedBox(width: 300, height: 14))),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ============================================================================
// 渐变专项场景（Impealler/Skia 渐变填充路径对比）
// ============================================================================

/// 全屏填充：同一几何，仅填充方式不同（纯色对照 / 线性 / 径向）
class GradFullPainter extends CustomPainter {
  GradFullPainter(this.t, {required this.radial});

  final double t;
  final bool radial;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final shift = (math.sin(t) + 1) / 2;
    final paint = Paint();
    if (radial) {
      paint.shader = ui.Gradient.radial(
        Offset(size.width * (0.2 + 0.6 * shift), size.height * 0.5),
        size.shortestSide * 0.9,
        <Color>[
          const Color(0xFF5B7CFA),
          const Color(0x229B5BFA),
          const Color(0x00000000),
        ],
        <double>[0.0, 0.5, 1.0],
      );
    } else {
      paint.shader = ui.Gradient.linear(
        Offset.zero,
        Offset(size.width, size.height),
        <Color>[
          Color.lerp(const Color(0x2EFFFFFF), const Color(0x88FFFFFF), shift)!,
          const Color(0x0FFFFFFF),
        ],
      );
    }
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(GradFullPainter oldDelegate) => true;
}

/// 10 个圆角面板 + 线性渐变 + 描边（≈ 玻璃面板填充方式）
class GradPanelsScene extends StatelessWidget {
  const GradPanelsScene({super.key, required this.t});

  final double t;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF1E1E40),
      child: Stack(
        children: <Widget>[
          for (var i = 0; i < 9; i++)
            Positioned(
              left: 20.0 + (i % 3) * 400,
              top: 20.0 + (i ~/ 3) * 230 + 6 * math.sin(t * 2 + i),
              child: Container(
                width: 380,
                height: 200,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: <Color>[Color(0x2EFFFFFF), Color(0x0FFFFFFF)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0x4DFFFFFF)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
