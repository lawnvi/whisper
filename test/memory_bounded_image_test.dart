import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/memory_bounded_image.dart';

void main() {
  test(
    'static images wait for decoding and discard cancelled queue entries',
    () async {
      final gate = Completer<ui.FrameInfo>();
      final frame = _Frame();
      final active = _Codec(gate.future);
      final cancelled = _Codec(Future.value(frame));
      final next = _Codec(Future.value(frame));
      final codecs = [
        active,
        cancelled,
        next,
      ].map(MemoryBoundedImageCodec.new).toList();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete(frame);
        for (final codec in codecs) {
          codec.dispose();
        }
      });
      final first = codecs[0].getNextFrame();
      final second = codecs[1].getNextFrame();
      final third = codecs[2].getNextFrame();
      final cancelledResult = expectLater(second, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect([active.calls, cancelled.calls, next.calls], [1, 0, 0]);
      codecs[1].dispose();
      gate.complete(frame);
      expect(await first, same(frame));
      await cancelledResult;
      expect(await third, same(frame));
      expect([active.calls, cancelled.calls, next.calls], [1, 0, 1]);
      expect(cancelled.disposed, isTrue);
    },
  );

  test('animation frames do not wait behind large static images', () async {
    final gate = Completer<ui.FrameInfo>();
    final frame = _Frame();
    final staticImage = MemoryBoundedImageCodec(_Codec(gate.future));
    final animation = MemoryBoundedImageCodec(
      _Codec(Future.value(frame), frames: 2),
    );
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(frame);
      staticImage.dispose();
      animation.dispose();
    });
    final pending = staticImage.getNextFrame();
    expect(await animation.getNextFrame(), same(frame));
    expect(gate.isCompleted, isFalse);
    gate.complete(frame);
    await pending;
  });
}

class _Codec implements ui.Codec {
  _Codec(this.result, {this.frames = 1});
  final Future<ui.FrameInfo> result;
  final int frames;
  int calls = 0;
  bool disposed = false;
  @override
  int get frameCount => frames;
  @override
  int get repetitionCount => 0;
  @override
  Future<ui.FrameInfo> getNextFrame() {
    calls++;
    return result;
  }

  @override
  void dispose() {
    disposed = true;
  }
}

class _Frame implements ui.FrameInfo {
  @override
  Duration get duration => Duration.zero;
  @override
  ui.Image get image => throw UnimplementedError();
}
