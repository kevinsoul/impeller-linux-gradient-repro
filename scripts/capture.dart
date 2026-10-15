// 用法: dart run bin/capture.dart <vm_service_ws_url> <seconds> <out_json>
// 连上 VM Service → 开启全部 timeline stream → 录制 N 秒 → 落盘 JSON
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('usage: capture.dart <ws_url> <seconds> <out_json>');
    exit(64);
  }
  final wsUrl = args[0];
  final seconds = int.parse(args[1]);
  final outPath = args[2];

  final vs = await vmServiceConnectUri(wsUrl);
  try {
    final vm = await vs.getVM();
    stdout.writeln('VM: ${vm.name} version=${vm.version} isolates=${vm.isolates?.map((e) => e.name).join(',')}');

    // 查可用 stream 并全部打开（Dart=UI 线程；Embedder/GPU 等=引擎线程）
    final flags = await vs.getVMTimelineFlags();
    final available = flags.availableStreams ?? <String>[];
    stdout.writeln('available streams: $available');
    await vs.setVMTimelineFlags(available);

    // 清空已有事件（方法在部分版本不存在，容错）
    try {
      await vs.clearVMTimeline();
    } catch (_) {
      stdout.writeln('clearVMTimeline 不可用，跳过');
    }

    stdout.writeln('>>> RECORDING ${seconds}s — 请开始滑动鼠标 <<<');
    await Future<void>.delayed(Duration(seconds: seconds));

    final timeline = await vs.getVMTimeline();
    final json = jsonEncode(timeline.toJson());
    await File(outPath).writeAsString(json);
    final events = timeline.traceEvents ?? [];
    stdout.writeln('>>> DONE: ${events.length} events -> $outPath');
  } finally {
    vs.dispose();
  }
}
