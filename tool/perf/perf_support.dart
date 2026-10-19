// Shared by the Flow perf harnesses in this folder: window pictures, input
// made up in code, and frame timings summed up per phase.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

const perfHues = [
  Colors.indigo,
  Colors.teal,
  Colors.orange,
  Colors.pink,
  Colors.blueGrey,
  Colors.green,
  Colors.purple,
  Colors.brown,
  Colors.cyan,
];

/// A window-like picture the size hosts send (480 on the long edge).
Future<Uint8List> perfWindowPicture(int index) async {
  const width = 480.0;
  const height = 300.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, width, height),
    Paint()..color = const Color(0xFFF5F5F7),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 120, height),
    Paint()..color = perfHues[index % perfHues.length].shade100,
  );
  final line = Paint()..color = const Color(0xFF8E8E93);
  final random = math.Random(index);
  for (var y = 20.0; y < height - 10; y += 14) {
    canvas.drawRect(
      Rect.fromLTWH(136, y, 120 + random.nextDouble() * 200, 6),
      line,
    );
  }
  final image = await recorder.endRecording().toImage(
    width.toInt(),
    height.toInt(),
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// Pointer input made up in code, with real time stamps (flings measure
/// speed from them).
class PerfInput {
  PerfInput({this.kind = PointerDeviceKind.touch});

  final PointerDeviceKind kind;
  final _clock = Stopwatch()..start();
  var _pointer = 900;
  var _mouseAdded = false;
  var _mouseAt = Offset.zero;

  void _event(PointerEvent event) =>
      GestureBinding.instance.handlePointerEvent(event);

  Duration get _now => _clock.elapsed;

  int get _id => kind == PointerDeviceKind.mouse ? 1 : ++_pointer;

  void _ensureMouse(Offset at) {
    if (kind != PointerDeviceKind.mouse || _mouseAdded) {
      return;
    }
    _mouseAdded = true;
    _mouseAt = at;
    _event(
      PointerAddedEvent(kind: kind, position: at, timeStamp: _now, pointer: 1),
    );
  }

  Future<void> tap(Offset at) async {
    _ensureMouse(at);
    await hoverTo(at, const Duration(milliseconds: 1));
    final pointer = _id;
    const buttons = kPrimaryButton;
    _event(
      PointerDownEvent(
        pointer: pointer,
        kind: kind,
        buttons: buttons,
        position: at,
        timeStamp: _now,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    _event(
      PointerUpEvent(
        pointer: pointer,
        kind: kind,
        position: at,
        timeStamp: _now,
      ),
    );
  }

  /// A mouse moving (no button) to [to] in [duration].
  Future<void> hoverTo(Offset to, Duration duration) async {
    if (kind != PointerDeviceKind.mouse) {
      return;
    }
    _ensureMouse(to);
    final from = _mouseAt;
    final steps = math.max(1, duration.inMilliseconds ~/ 8);
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 8));
      final at = Offset.lerp(from, to, i / steps)!;
      _event(
        PointerHoverEvent(
          pointer: 1,
          kind: kind,
          position: at,
          delta: at - _mouseAt,
          timeStamp: _now,
        ),
      );
      _mouseAt = at;
    }
  }

  /// One wheel notch's worth of scrolling at the mouse.
  void wheel(double dy) {
    _event(
      PointerScrollEvent(
        kind: PointerDeviceKind.mouse,
        position: _mouseAt,
        scrollDelta: Offset(0, dy),
        timeStamp: _now,
      ),
    );
  }

  /// A finger (or held button) from [from] to [to] in [duration], a move
  /// every 8 ms, then let go (moving: a fling).
  Future<void> swipe(Offset from, Offset to, Duration duration) async {
    final pointer = _id;
    const buttons = kPrimaryButton;
    _event(
      PointerDownEvent(
        pointer: pointer,
        kind: kind,
        buttons: buttons,
        position: from,
        timeStamp: _now,
      ),
    );
    final steps = duration.inMilliseconds ~/ 8;
    var last = from;
    for (var i = 1; i <= steps; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 8));
      final t = Curves.easeInOut.transform(i / steps);
      final at = Offset.lerp(from, to, t)!;
      _event(
        PointerMoveEvent(
          pointer: pointer,
          kind: kind,
          buttons: buttons,
          position: at,
          delta: at - last,
          timeStamp: _now,
        ),
      );
      last = at;
    }
    _event(
      PointerUpEvent(
        pointer: pointer,
        kind: kind,
        position: last,
        timeStamp: _now,
      ),
    );
  }
}

/// Frame timings while [phase] runs, printed as one `perf:` line.
Future<void> measure(String name, Future<void> Function() phase) async {
  final timings = <FrameTiming>[];
  void keep(List<FrameTiming> list) => timings.addAll(list);
  SchedulerBinding.instance.addTimingsCallback(keep);
  final clock = Stopwatch()..start();
  await phase();
  // Timings come in batches; the last ones within a second or so.
  for (var i = 0; i < 3; i++) {
    SchedulerBinding.instance.scheduleFrame();
    await SchedulerBinding.instance.endOfFrame;
  }
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  SchedulerBinding.instance.removeTimingsCallback(keep);
  clock.stop();
  perfLog('perf: $name ${summarize(timings, clock.elapsed)}');
}

/// Where the text [label] is on screen (its first widget), for a tap.
Offset? perfFindText(BuildContext context, String label) {
  Offset? found;
  void visit(Element element) {
    if (found != null) {
      return;
    }
    final widget = element.widget;
    if (widget is Text && widget.data == label) {
      final box = element.findRenderObject();
      if (box is RenderBox && box.hasSize) {
        found = box.localToGlobal(box.size.center(Offset.zero));
        return;
      }
    }
    element.visitChildren(visit);
  }

  context.visitChildElements(visit);
  return found;
}

/// This run's name (`--dart-define=WHISPER_PERF_RUN=…`), so a results file
/// left from an earlier run is not taken for this one's.
const perfRun = String.fromEnvironment('WHISPER_PERF_RUN');

/// Starts a new results file (see [perfLog]).
void perfStart() {
  try {
    File('${Directory.systemTemp.path}/whisper_perf.txt').writeAsStringSync('');
  } on FileSystemException {
    // Printed is enough.
  }
  perfLog('perf: run $perfRun');
}

void perfDone() => perfLog('perf: done $perfRun');

/// Printed, and kept in the system temp folder's `whisper_perf.txt` (a
/// phone's app container `tmp/`, where its console cannot be read).
void perfLog(String line) {
  // ignore: avoid_print
  print(line);
  try {
    File(
      '${Directory.systemTemp.path}/whisper_perf.txt',
    ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } on FileSystemException {
    // Printed is enough.
  }
}

String summarize(List<FrameTiming> timings, Duration over) {
  if (timings.isEmpty) {
    return 'frames 0 in ${over.inMilliseconds}ms';
  }
  double ms(Duration d) => d.inMicroseconds / 1000;
  List<double> sorted(Iterable<double> values) => values.toList()..sort();
  double at(List<double> values, double q) =>
      values[((values.length - 1) * q).round()];
  final build = sorted(timings.map((t) => ms(t.buildDuration)));
  final raster = sorted(timings.map((t) => ms(t.rasterDuration)));
  final total = sorted(timings.map((t) => ms(t.totalSpan)));
  final rate = WidgetsBinding
      .instance
      .platformDispatcher
      .views
      .first
      .display
      .refreshRate;
  final refresh = 1000 / (rate > 0 ? rate : 60);
  var skipped = 0;
  for (var i = 1; i < timings.length; i++) {
    final gap =
        (timings[i].timestampInMicroseconds(ui.FramePhase.vsyncStart) -
            timings[i - 1].timestampInMicroseconds(ui.FramePhase.vsyncStart)) /
        1000;
    // Frames come only while something moves; a long gap between two
    // gestures is not a missed frame.
    if (gap > refresh * 1.5 && gap < 120) {
      skipped += (gap / refresh).round() - 1;
    }
  }
  String line(String name, List<double> v) =>
      '$name ${at(v, 0.5).toStringAsFixed(1)}/'
      '${at(v, 0.9).toStringAsFixed(1)}/'
      '${at(v, 0.99).toStringAsFixed(1)}/'
      '${v.last.toStringAsFixed(1)}';
  final late = total.where((v) => v > refresh).length;
  return 'frames ${timings.length} in ${over.inMilliseconds}ms '
      '(${refresh.toStringAsFixed(1)}ms each) late $late skipped $skipped | '
      'p50/p90/p99/max ${line('build', build)} ${line('raster', raster)} '
      '${line('total', total)}';
}
