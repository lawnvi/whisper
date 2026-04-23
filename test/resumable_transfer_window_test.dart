import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/resumable_transfer_window.dart';

void main() {
  group('resumable transfer windowing', () {
    test('splits a 32 MiB transfer window into 4 MiB read frames', () {
      final ranges = buildTransferWindowFrames(
        startOffset: 0,
        totalSize: WsSvrManager.defaultTransferChunkSize * 2,
        windowSize: WsSvrManager.defaultTransferChunkSize,
        framePayloadSize: WsSvrManager.transferFramePayloadSize,
      );

      expect(ranges, hasLength(8));
      expect(ranges.first.offset, 0);
      expect(ranges.first.length, WsSvrManager.transferFramePayloadSize);
      expect(ranges.last.offset, 28 * 1024 * 1024);
      expect(ranges.last.length, WsSvrManager.transferFramePayloadSize);
    });

    test('caps the final transfer window to the remaining file size', () {
      final ranges = buildTransferWindowFrames(
        startOffset: 32 * 1024 * 1024,
        totalSize: 40 * 1024 * 1024,
        windowSize: WsSvrManager.defaultTransferChunkSize,
        framePayloadSize: WsSvrManager.transferFramePayloadSize,
      );

      expect(ranges, hasLength(2));
      expect(ranges.first.offset, 32 * 1024 * 1024);
      expect(ranges.first.length, WsSvrManager.transferFramePayloadSize);
      expect(ranges.last.offset, 36 * 1024 * 1024);
      expect(ranges.last.length, WsSvrManager.transferFramePayloadSize);
    });

    test('splits raw payload frames into 64 KiB websocket messages', () {
      final ranges = buildTransferRawPayloadFrames(
        startOffset: 0,
        payloadLength: WsSvrManager.transferFramePayloadSize,
        rawFramePayloadSize: WsSvrManager.transferRawFramePayloadSize,
      );

      expect(ranges, hasLength(64));
      expect(ranges.first.offset, 0);
      expect(ranges.first.length, WsSvrManager.transferRawFramePayloadSize);
      expect(ranges.last.offset, 63 * 64 * 1024);
      expect(ranges.last.length, WsSvrManager.transferRawFramePayloadSize);
    });

    test('emits UI progress more frequently than durable transfer windows', () {
      expect(
        shouldEmitTransferUiProgress(
          bytesSinceLastUiProgress: 256 * 1024,
          elapsedSinceLastUiProgress: const Duration(milliseconds: 500),
          committedBytes: 256 * 1024,
          totalSize: 10 * 1024 * 1024,
        ),
        isFalse,
      );
      expect(
        shouldEmitTransferUiProgress(
          bytesSinceLastUiProgress: 512 * 1024,
          elapsedSinceLastUiProgress: const Duration(milliseconds: 120),
          committedBytes: 512 * 1024,
          totalSize: 10 * 1024 * 1024,
        ),
        isFalse,
      );
      expect(
        shouldEmitTransferUiProgress(
          bytesSinceLastUiProgress: 512 * 1024,
          elapsedSinceLastUiProgress: const Duration(milliseconds: 150),
          committedBytes: 512 * 1024,
          totalSize: 10 * 1024 * 1024,
        ),
        isTrue,
      );
    });

    test('always emits progress at transfer and window boundaries', () {
      expect(
        shouldEmitTransferUiProgress(
          bytesSinceLastUiProgress: 64 * 1024,
          elapsedSinceLastUiProgress: Duration.zero,
          committedBytes: 10 * 1024 * 1024,
          totalSize: 10 * 1024 * 1024,
        ),
        isTrue,
      );
      expect(
        shouldEmitTransferUiProgress(
          bytesSinceLastUiProgress: 64 * 1024,
          elapsedSinceLastUiProgress: Duration.zero,
          committedBytes: 32 * 1024 * 1024,
          totalSize: 100 * 1024 * 1024,
          force: true,
        ),
        isTrue,
      );
    });
  });
}
