import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/remote_input/remote_clipboard_transfer.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'publishes metadata first and transfers bytes only when peer pastes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'whisper-clipboard-test',
      );
      const writerChannel = MethodChannel('test_remote_clipboard_writer');
      final writtenPaths = <String>[];
      var writtenAsImage = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(writerChannel, (call) async {
            expect(call.method, 'writeFilePaths');
            writtenPaths.addAll(
              List<String>.from((call.arguments as Map)['paths'] as List),
            );
            writtenAsImage = (call.arguments as Map)['asImage'] == true;
            return true;
          });
      late RemoteClipboardTransferEngine source;
      late RemoteClipboardTransferEngine sink;
      final sourceFrames = <WhisperFrameType>[];
      final sinkFrames = <WhisperFrameType>[];
      source = RemoteClipboardTransferEngine(
        currentBinding: (peerId) => peerId == 'sink'
            ? const TransferConnectionBinding(peerId: 'sink', generation: 1)
            : null,
        sessionValidator:
            ({required peerId, required sessionId, required sourceIsLocal}) =>
                peerId == 'sink' && sessionId == 'session' && sourceIsLocal,
        sendFrame: (binding, frame) async {
          sourceFrames.add(frame.type);
          await sink.handleFrame(
            const TransferConnectionBinding(peerId: 'source', generation: 1),
            frame,
          );
          return true;
        },
      );
      sink = RemoteClipboardTransferEngine(
        currentBinding: (peerId) => peerId == 'source'
            ? const TransferConnectionBinding(peerId: 'source', generation: 1)
            : null,
        sessionValidator:
            ({required peerId, required sessionId, required sourceIsLocal}) =>
                peerId == 'source' && sessionId == 'session' && !sourceIsLocal,
        sendFrame: (binding, frame) async {
          sinkFrames.add(frame.type);
          await source.handleFrame(
            const TransferConnectionBinding(peerId: 'sink', generation: 1),
            frame,
          );
          return true;
        },
        writer: const DesktopClipboardFileWriter(channel: writerChannel),
        directoryProvider: () async => root,
      );

      final bytes = Uint8List.fromList(
        List<int>.generate(1024, (i) => i % 251),
      );
      expect(
        await source.publish(
          peerId: 'sink',
          sessionId: 'session',
          items: <RemoteClipboardLocalItem>[
            RemoteClipboardLocalItem.bytes('sample.png', bytes),
          ],
        ),
        isTrue,
      );
      expect(sourceFrames, <WhisperFrameType>[WhisperFrameType.clipboardOffer]);
      expect(writtenPaths, isEmpty);

      expect(
        await sink.preparePaste(peerId: 'source', sessionId: 'session'),
        RemoteClipboardPasteResult.prepared,
      );
      expect(sinkFrames, contains(WhisperFrameType.clipboardRequest));
      expect(sourceFrames, contains(WhisperFrameType.clipboardData));
      expect(sourceFrames.last, WhisperFrameType.clipboardComplete);
      expect(writtenPaths, hasLength(1));
      expect(writtenAsImage, isTrue);
      expect(await File(writtenPaths.single).readAsBytes(), bytes);

      final cachedPath = writtenPaths.single;
      await sink.clearSession('session');
      expect(await File(cachedPath).exists(), isFalse);
      await root.delete(recursive: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(writerChannel, null);
    },
  );

  test(
    'rejects an oversized clipboard item before sending its bytes',
    () async {
      final sent = <WhisperFrameType>[];
      final engine = RemoteClipboardTransferEngine(
        currentBinding: (_) =>
            const TransferConnectionBinding(peerId: 'sink', generation: 1),
        sessionValidator:
            ({required peerId, required sessionId, required sourceIsLocal}) =>
                true,
        sendFrame: (binding, frame) async {
          sent.add(frame.type);
          return true;
        },
      );

      expect(
        await engine.publish(
          peerId: 'sink',
          sessionId: 'session',
          items: <RemoteClipboardLocalItem>[
            RemoteClipboardLocalItem(
              name: 'huge.bin',
              size: remoteClipboardMaxFileBytes + 1,
              openRead: () => const Stream<List<int>>.empty(),
            ),
          ],
        ),
        isFalse,
      );
      expect(sent, isNot(contains(WhisperFrameType.clipboardData)));
    },
  );

  test(
    'relays a controlled-device file only after another device pastes',
    () async {
      final brokerRoot = await Directory.systemTemp.createTemp(
        'whisper-clipboard-broker',
      );
      final targetRoot = await Directory.systemTemp.createTemp(
        'whisper-clipboard-target',
      );
      const writerChannel = MethodChannel('test_workspace_clipboard_writer');
      final writtenPaths = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(writerChannel, (call) async {
            writtenPaths.addAll(
              List<String>.from((call.arguments as Map)['paths'] as List),
            );
            return true;
          });
      late RemoteClipboardTransferEngine origin;
      late RemoteClipboardTransferEngine broker;
      late RemoteClipboardTransferEngine target;
      final originFrames = <WhisperFrameType>[];
      origin = RemoteClipboardTransferEngine(
        currentBinding: (peerId) => peerId == 'broker'
            ? const TransferConnectionBinding(peerId: 'broker', generation: 1)
            : null,
        sessionValidator:
            ({required peerId, required sessionId, required sourceIsLocal}) =>
                peerId == 'broker' && sessionId == 'origin-session',
        sendFrame: (binding, frame) async {
          originFrames.add(frame.type);
          await broker.handleFrame(
            const TransferConnectionBinding(peerId: 'origin', generation: 1),
            frame,
          );
          return true;
        },
      );
      broker = RemoteClipboardTransferEngine(
        currentBinding: (peerId) =>
            TransferConnectionBinding(peerId: peerId, generation: 1),
        sessionValidator:
            ({required peerId, required sessionId, required sourceIsLocal}) =>
                (peerId == 'origin' && sessionId == 'origin-session') ||
                (peerId == 'target' && sessionId == 'target-session'),
        sendFrame: (binding, frame) async {
          if (binding.peerId == 'origin') {
            await origin.handleFrame(
              const TransferConnectionBinding(peerId: 'broker', generation: 1),
              frame,
            );
          } else if (binding.peerId == 'target') {
            await target.handleFrame(
              const TransferConnectionBinding(peerId: 'broker', generation: 1),
              frame,
            );
          }
          return true;
        },
        directoryProvider: () async => brokerRoot,
      );
      target = RemoteClipboardTransferEngine(
        currentBinding: (peerId) => peerId == 'broker'
            ? const TransferConnectionBinding(peerId: 'broker', generation: 1)
            : null,
        sessionValidator:
            ({required peerId, required sessionId, required sourceIsLocal}) =>
                peerId == 'broker' && sessionId == 'target-session',
        sendFrame: (binding, frame) async {
          await broker.handleFrame(
            const TransferConnectionBinding(peerId: 'target', generation: 1),
            frame,
          );
          return true;
        },
        writer: const DesktopClipboardFileWriter(channel: writerChannel),
        directoryProvider: () async => targetRoot,
      );

      final bytes = Uint8List.fromList(
        List<int>.generate(4096, (i) => i % 239),
      );
      expect(
        await origin.publish(
          peerId: 'broker',
          sessionId: 'origin-session',
          items: <RemoteClipboardLocalItem>[
            RemoteClipboardLocalItem.bytes('from-origin.png', bytes),
          ],
        ),
        isTrue,
      );
      expect(originFrames, <WhisperFrameType>[WhisperFrameType.clipboardOffer]);
      expect(
        await broker.relayRemoteOffer(
          originPeerId: 'origin',
          originSessionId: 'origin-session',
          targetPeerId: 'target',
          targetSessionId: 'target-session',
        ),
        isTrue,
      );
      expect(originFrames, <WhisperFrameType>[WhisperFrameType.clipboardOffer]);

      expect(
        await target.preparePaste(
          peerId: 'broker',
          sessionId: 'target-session',
        ),
        RemoteClipboardPasteResult.prepared,
      );
      expect(originFrames, contains(WhisperFrameType.clipboardData));
      expect(await File(writtenPaths.single).readAsBytes(), bytes);

      await broker.clearSession('origin-session');
      await target.clearSession('target-session');
      await brokerRoot.delete(recursive: true);
      await targetRoot.delete(recursive: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(writerChannel, null);
    },
  );
}
