import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_key_translation.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_scroll.dart';

void main() {
  group('RemoteInputScrollNormalizer', () {
    test('annotates Windows wheel deltas as wheel ticks', () {
      final annotated = RemoteInputScrollNormalizer.annotateSourceFrame(
        _wheelFrame(<String, dynamic>{
          'deltaX': 0,
          'deltaY': 120,
        }),
        sourcePlatform: RemoteInputPlatformKind.windows,
      );

      final payload = _payload(annotated);

      expect(payload['sourcePlatform'], 'windows');
      expect(payload['scrollUnit'], 'wheel');
      expect(payload['scrollDeltaX'], 0);
      expect(payload['scrollDeltaY'], 1);
      expect(payload['deltaY'], 120);
    });

    test('uses macOS point deltas as pixel scroll', () {
      final annotated = RemoteInputScrollNormalizer.annotateSourceFrame(
        _wheelFrame(<String, dynamic>{
          'deltaX': 0,
          'deltaY': 1,
          'pointDeltaX': 0,
          'pointDeltaY': 12,
          'isContinuous': true,
        }),
        sourcePlatform: RemoteInputPlatformKind.macos,
      );

      final payload = _payload(annotated);

      expect(payload['sourcePlatform'], 'macos');
      expect(payload['scrollUnit'], 'pixel');
      expect(payload['scrollDeltaY'], 12);
      expect(payload['deltaY'], 1);
    });

    test('normalizes wheel ticks to macOS pixels with multiplier', () {
      final normalized = RemoteInputScrollNormalizer.normalizeForTarget(
        _wheelFrame(<String, dynamic>{
          'sourcePlatform': 'windows',
          'scrollUnit': 'wheel',
          'scrollDeltaX': 0,
          'scrollDeltaY': 1,
          'deltaX': 0,
          'deltaY': 120,
        }),
        targetPlatform: RemoteInputPlatformKind.macos,
        scrollMultiplier: 2,
      );

      final payload = _payload(normalized);

      expect(payload['deltaX'], 0);
      expect(payload['deltaY'], 240);
      expect(payload['targetScrollUnit'], 'pixel');
      expect(payload['scrollMultiplier'], 2);
    });

    test('infers legacy macOS deltas as wheel ticks', () {
      final normalized = RemoteInputScrollNormalizer.normalizeForTarget(
        _wheelFrame(<String, dynamic>{
          'deltaX': 0,
          'deltaY': 1,
        }),
        targetPlatform: RemoteInputPlatformKind.macos,
        scrollMultiplier: 1,
        fallbackSourcePlatform: RemoteInputPlatformKind.macos,
      );

      final payload = _payload(normalized);

      expect(payload['scrollUnit'], 'wheel');
      expect(payload['scrollDeltaY'], 1);
      expect(payload['deltaY'], 120);
    });

    test('normalizes wheel ticks to Windows wheel deltas', () {
      final normalized = RemoteInputScrollNormalizer.normalizeForTarget(
        _wheelFrame(<String, dynamic>{
          'sourcePlatform': 'linux',
          'scrollUnit': 'wheel',
          'scrollDeltaX': 0,
          'scrollDeltaY': -1,
          'deltaX': 0,
          'deltaY': -120,
        }),
        targetPlatform: RemoteInputPlatformKind.windows,
        scrollMultiplier: 1.5,
      );

      final payload = _payload(normalized);

      expect(payload['deltaX'], 0);
      expect(payload['deltaY'], -180);
      expect(payload['targetScrollUnit'], 'wheel');
    });
  });
}

RemoteInputPacketFrame _wheelFrame(Map<String, dynamic> payload) {
  return RemoteInputPacketFrame(
    sessionId: 'input-scroll-1',
    sequence: 1,
    timestampMicros: 2,
    eventType: RemoteInputEventType.mouseWheel,
    payload: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
  );
}

Map<String, dynamic> _payload(RemoteInputPacketFrame frame) {
  return jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
}
