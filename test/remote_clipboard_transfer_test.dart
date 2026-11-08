import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/remote_files/fs_placement.dart';
import 'package:whisper/remote_input/remote_clipboard_paste_watch.dart';
import 'package:whisper/remote_input/remote_clipboard_transfer.dart';
import 'package:whisper/socket/bounded_receive_queue.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a failed old request cannot remove its replacement', () async {
    final root = await Directory.systemTemp.createTemp('whisper-replaced');
    const binding = TransferConnectionBinding(peerId: 'source', generation: 1);
    const channel = MethodChannel('test_replaced_clipboard');
    final oldStarted = Completer<void>(), newStarted = Completer<void>();
    final oldSend = Completer<bool>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => true);
    final engine = RemoteClipboardTransferEngine(
      currentBinding: (_) => binding,
      sessionValidator:
          ({required peerId, required sessionId, required sourceIsLocal}) =>
              true,
      directoryProvider: () async => root,
      writer: const DesktopClipboardFileWriter(channel: channel),
      sendFrame: (_, frame) async {
        if (frame.transferId == 'old') {
          oldStarted.complete();
          return oldSend.future;
        }
        newStarted.complete();
        return true;
      },
    );
    addTearDown(() async {
      if (!oldSend.isCompleted) oldSend.complete(false);
      await engine.clearSession('session');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    });
    WhisperFrameV3 frame(String id, WhisperFrameType type) => WhisperFrameV3(
      type: type,
      transferId: id,
      offset: 0,
      sequence: type == WhisperFrameType.clipboardComplete ? 1 : 0,
      payload: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'protocolVersion': 1,
            'sessionId': 'session',
            'items': [
              {'name': 'file.txt', 'size': 0, 'kind': 'file'},
            ],
          }),
        ),
      ),
    );
    await engine.handleFrame(
      binding,
      frame('old', WhisperFrameType.clipboardOffer),
    );
    final oldPaste = engine.preparePaste(
      peerId: 'source',
      sessionId: 'session',
    );
    await oldStarted.future;
    await engine.handleFrame(
      binding,
      frame('new', WhisperFrameType.clipboardOffer),
    );
    final newPaste = engine.preparePaste(
      peerId: 'source',
      sessionId: 'session',
    );
    await newStarted.future;
    oldSend.complete(false);
    await oldPaste;
    await engine.handleFrame(
      binding,
      frame('new', WhisperFrameType.clipboardComplete),
    );
    expect(
      await newPaste.timeout(const Duration(seconds: 1)),
      RemoteClipboardPasteResult.prepared,
    );
  });

  test(
    'screenshot download leaves the receive queue free and shares a pending paste',
    () async {
      final root = await Directory.systemTemp.createTemp('whisper-image-queue');
      final queue = BoundedReceiveQueue();
      final started = Completer<void>();
      final imageReady = Completer<void>();
      final written = Completer<List<int>>();
      const channel = MethodChannel('test_image_queue_writer');
      var requestCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final path = (call.arguments as Map)['paths'][0] as String;
            expect((call.arguments as Map)['asImage'], isTrue);
            final bytes = await File(path).readAsBytes();
            if (!written.isCompleted) written.complete(bytes);
            return true;
          });
      late RemoteClipboardTransferEngine source;
      late RemoteClipboardTransferEngine sink;
      source = RemoteClipboardTransferEngine(
        currentBinding: (_) =>
            const TransferConnectionBinding(peerId: 'sink', generation: 1),
        sessionValidator:
            ({required peerId, required sessionId, required sourceIsLocal}) =>
                true,
        sendFrame: (_, frame) => queue.add(
          frame.encode().length,
          () => sink.handleFrame(
            const TransferConnectionBinding(peerId: 'source', generation: 1),
            frame,
            prepareImages: true,
          ),
        ),
      );
      sink = RemoteClipboardTransferEngine(
        currentBinding: (_) =>
            const TransferConnectionBinding(peerId: 'source', generation: 1),
        sessionValidator:
            ({required peerId, required sessionId, required sourceIsLocal}) =>
                true,
        directoryProvider: () async => root,
        writer: const DesktopClipboardFileWriter(channel: channel),
        sendFrame: (_, frame) async {
          if (frame.type == WhisperFrameType.clipboardRequest) requestCount++;
          await source.handleFrame(
            const TransferConnectionBinding(peerId: 'sink', generation: 1),
            frame,
          );
          return true;
        },
      );
      addTearDown(() async {
        if (!imageReady.isCompleted) imageReady.complete();
        await source.clearSession('session');
        await sink.clearSession('session');
        await queue.closeAndDrain();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await root.delete(recursive: true);
      });
      final bytes = Uint8List.fromList(
        List<int>.generate(1024, (i) => i % 251),
      );
      expect(
        await source
            .publish(
              peerId: 'sink',
              sessionId: 'session',
              items: [
                RemoteClipboardLocalItem(
                  name: 'screenshot.png',
                  size: bytes.length,
                  isImage: true,
                  openRead: () async* {
                    if (!started.isCompleted) started.complete();
                    await imageReady.future;
                    yield bytes;
                  },
                ),
              ],
            )
            .timeout(const Duration(seconds: 2)),
        isTrue,
      );
      await started.future.timeout(const Duration(seconds: 2));
      var releaseHandled = false;
      await queue
          .add(1, () async {
            releaseHandled = true;
          })
          .timeout(const Duration(seconds: 2));
      expect(releaseHandled, isTrue);
      expect(written.isCompleted, isFalse);
      final paste = sink.preparePaste(peerId: 'source', sessionId: 'session');
      await Future<void>.delayed(Duration.zero);
      expect(requestCount, 1);
      imageReady.complete();
      expect(
        await paste.timeout(const Duration(seconds: 2)),
        RemoteClipboardPasteResult.prepared,
      );
      expect(await written.future.timeout(const Duration(seconds: 2)), bytes);
    },
  );

  test(
    'a local copy cancels a pending image without writing stale data or rejecting late completion',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'whisper-image-cancel',
      );
      final opening = Completer<void>();
      final resume = Completer<void>();
      final sent = <WhisperFrameType>[];
      final engine = RemoteClipboardTransferEngine(
        currentBinding: (_) =>
            const TransferConnectionBinding(peerId: 'source', generation: 1),
        sessionValidator:
            ({required peerId, required sessionId, required sourceIsLocal}) =>
                true,
        directoryProvider: () async {
          opening.complete();
          await resume.future;
          return root;
        },
        sendFrame: (_, frame) async {
          sent.add(frame.type);
          return true;
        },
      );
      addTearDown(() async {
        if (!resume.isCompleted) resume.complete();
        await engine.clearSession('session');
        await root.delete(recursive: true);
      });
      const binding = TransferConnectionBinding(
        peerId: 'source',
        generation: 1,
      );
      await engine.handleFrame(
        binding,
        WhisperFrameV3(
          type: WhisperFrameType.clipboardOffer,
          transferId: 'offer',
          offset: 0,
          sequence: 0,
          payload: Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'protocolVersion': 1,
                'sessionId': 'session',
                'items': [
                  {'name': 'image.png', 'size': 4, 'kind': 'image'},
                ],
              }),
            ),
          ),
        ),
      );
      final paste = engine.preparePaste(peerId: 'source', sessionId: 'session');
      await opening.future;
      await engine.clearSession('session');
      resume.complete();
      expect(await paste, RemoteClipboardPasteResult.notAvailable);
      expect(sent, isEmpty);
      await engine.handleFrame(
        binding,
        WhisperFrameV3(
          type: WhisperFrameType.clipboardComplete,
          transferId: 'offer',
          offset: 4,
          sequence: 1,
          payload: Uint8List.fromList(
            utf8.encode('{"protocolVersion":1,"sessionId":"session"}'),
          ),
        ),
      );
      expect(
        engine.remoteOffer(peerId: 'source', sessionId: 'session'),
        isNull,
      );
    },
  );

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
      await sink.clearSession('session', endsPaste: true);
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

  group('files as file transfers', () {
    late Directory root;
    late Directory sourceDir;
    late Directory downloads;
    late List<List<String>> written;
    const channel = MethodChannel('test_clipboard_transfers_writer');

    setUp(() async {
      root = await Directory.systemTemp.createTemp('whisper-clip-transfer');
      sourceDir = await Directory('${root.path}/source').create();
      downloads = await Directory('${root.path}/downloads').create();
      written = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            written.add(
              ((call.arguments as Map)['paths'] as List).cast<String>(),
            );
            return true;
          });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    });

    Future<RemoteClipboardLocalItem> file(String name, int size) async {
      final path = '${sourceDir.path}/$name';
      await File(path).writeAsBytes(List<int>.generate(size, (i) => i % 251));
      return RemoteClipboardLocalItem.file(
        ClipboardFileDraft(path: path, fileName: name, size: size),
      );
    }

    /// A source and a sink joined back to back. [newSource] and [newSink]
    /// say which can use file transfers; [sentAsFiles] collects what the
    /// source sent that way, and lands it as the transfer engine would.
    ({
      RemoteClipboardTransferEngine source,
      RemoteClipboardTransferEngine sink,
      List<String> frames,
      List<String> sentAsFiles,
    })
    pair({
      required bool newSource,
      required bool newSink,
      Future<void>? landAfter,
    }) {
      final frames = <String>[];
      final sentAsFiles = <String>[];
      final placements = TransferPlacements();
      late RemoteClipboardTransferEngine source;
      late RemoteClipboardTransferEngine sink;
      const toSink = TransferConnectionBinding(peerId: 'sink', generation: 1);
      const toSource = TransferConnectionBinding(
        peerId: 'source',
        generation: 1,
      );
      bool valid({
        required String peerId,
        required String sessionId,
        required bool sourceIsLocal,
      }) => true;
      source = RemoteClipboardTransferEngine(
        currentBinding: (_) => toSink,
        sessionValidator: valid,
        sendFrame: (_, frame) async {
          frames.add(frame.type.name);
          await sink.handleFrame(toSource, frame);
          return true;
        },
        sendFile: !newSource
            ? null
            : (peerId, path, transferId) async {
                sentAsFiles.add(transferId);
                await landAfter;
                final landed = await File(
                  path,
                ).copy('${downloads.path}/${path.split('/').last}');
                // As the engine reports it once the file is verified.
                unawaited(
                  placements.onTransferUpdated(
                    TransferSnapshot(
                      transferId: transferId,
                      messageUuid: transferId,
                      peerUid: 'source',
                      direction: FileTransferDirection.incoming,
                      state: FileTransferState.completed,
                      finalPath: landed.path,
                      tempPath: '',
                      size: await landed.length(),
                      committedBytes: await landed.length(),
                      lastError: '',
                      updatedAt: 0,
                    ),
                  ),
                );
                return true;
              },
        cancelTransfer: newSource ? (_) async {} : null,
        placements: newSource ? TransferPlacements() : null,
      );
      sink = RemoteClipboardTransferEngine(
        currentBinding: (_) => toSource,
        sessionValidator: valid,
        directoryProvider: () async => root,
        writer: const DesktopClipboardFileWriter(channel: channel),
        sendFrame: (_, frame) async {
          frames.add(frame.type.name);
          unawaited(source.handleFrame(toSink, frame));
          return true;
        },
        sendFile: newSink ? (_, __, ___) async => false : null,
        cancelTransfer: newSink ? (_) async {} : null,
        placements: newSink ? placements : null,
      );
      return (
        source: source,
        sink: sink,
        frames: frames,
        sentAsFiles: sentAsFiles,
      );
    }

    test(
      'copied over while its files come, the paste still gets them',
      () async {
        final land = Completer<void>();
        final link = pair(
          newSource: true,
          newSink: true,
          landAfter: land.future,
        );
        final item = await file('report.pdf', 3000);
        await link.source.publish(
          peerId: 'sink',
          sessionId: 's',
          items: [item],
        );
        final pasting = link.sink.preparePaste(
          peerId: 'source',
          sessionId: 's',
        );
        await pumpEventQueue();
        expect(link.sentAsFiles, hasLength(1));
        // Something else copied on both sides while the file is on its way.
        await link.sink.clearSession('s');
        await link.source.clearSession('s', notifyPeer: true, peerId: 'sink');
        land.complete();
        expect(await pasting, RemoteClipboardPasteResult.prepared);
        expect(written.single.single, endsWith('report.pdf'));
        expect(link.sink.ownsClipboardPaths('s', written.single), isTrue);
      },
    );

    test('put into a folder, nothing there is overwritten', () async {
      final link = pair(newSource: true, newSink: true);
      final item = await file('report.pdf', 3000);
      await link.source.publish(peerId: 'sink', sessionId: 's', items: [item]);
      expect(
        await link.sink.preparePaste(peerId: 'source', sessionId: 's'),
        RemoteClipboardPasteResult.prepared,
      );
      final folder = await Directory('${root.path}/desk').create();
      await File('${folder.path}/report.pdf').writeAsString('mine');
      final key = link.sink.pasteKey('s')!;
      expect(await link.sink.placeInto(key, folder.path), isTrue);
      expect(await File('${folder.path}/report.pdf').readAsString(), 'mine');
      expect(await File('${folder.path}/report 2.pdf').length(), 3000);
    });

    test('a paste while another one\'s files come waits its turn', () async {
      final land = Completer<void>();
      final link = pair(newSource: true, newSink: true, landAfter: land.future);
      final first = await file('first.bin', 3000);
      await link.source.publish(peerId: 'sink', sessionId: 's', items: [first]);
      final pastingFirst = link.sink.preparePaste(
        peerId: 'source',
        sessionId: 's',
      );
      await pumpEventQueue();
      // Something else copied, and pasted, before the first came.
      final second = await file('second.bin', 2000);
      await link.source.publish(
        peerId: 'sink',
        sessionId: 's',
        items: [second],
      );
      final pastingSecond = link.sink.preparePaste(
        peerId: 'source',
        sessionId: 's',
      );
      await pumpEventQueue();
      expect(link.sentAsFiles, hasLength(2));
      land.complete();
      expect(await pastingFirst, RemoteClipboardPasteResult.prepared);
      expect(await pastingSecond, RemoteClipboardPasteResult.prepared);
      expect(written.map((paths) => paths.single.split('/').last).toSet(), {
        'first.bin',
        'second.bin',
      });
    });

    test('the session over, a waiting paste stops', () async {
      final land = Completer<void>();
      final link = pair(newSource: true, newSink: true, landAfter: land.future);
      final item = await file('report.pdf', 3000);
      await link.source.publish(peerId: 'sink', sessionId: 's', items: [item]);
      final pasting = link.sink.preparePaste(peerId: 'source', sessionId: 's');
      await pumpEventQueue();
      await link.sink.clearSession('s', endsPaste: true);
      land.complete();
      expect(await pasting, isNot(RemoteClipboardPasteResult.prepared));
      expect(written, isEmpty);
    });

    test('both new: a large file comes as a transfer, on paste only', () async {
      final link = pair(newSource: true, newSink: true);
      // Over the frame limits, which only transfers take.
      final big = RemoteClipboardLocalItem(
        name: 'big.bin',
        size: remoteClipboardMaxFileBytes + 1,
        openRead: () => const Stream.empty(),
        resolvePath: () async => '${sourceDir.path}/big.bin',
      );
      expect(
        await link.source.publish(
          peerId: 'sink',
          sessionId: 'session',
          items: [big],
        ),
        isTrue,
      );
      // An older sink turns it down: it must not keep pasting the last one.
      expect(link.frames.take(2), ['clipboardClear', 'clipboardOffer']);
      expect(link.sentAsFiles, isEmpty, reason: 'nothing before the paste');

      final small = await file('notes.txt', 3000);
      expect(
        await link.source.publish(
          peerId: 'sink',
          sessionId: 'session',
          items: [small, await file('photo.jpg', 5000)],
        ),
        isTrue,
      );
      expect(link.sentAsFiles, isEmpty);
      final result = await link.sink
          .preparePaste(peerId: 'source', sessionId: 'session')
          .timeout(const Duration(seconds: 5));
      expect(result, RemoteClipboardPasteResult.prepared);
      expect(link.sentAsFiles, hasLength(2));
      expect(link.frames, isNot(contains('clipboardData')));
      final paths = written.single;
      expect(paths.map((path) => path.split('/').last), [
        'notes.txt',
        'photo.jpg',
      ]);
      expect(await File(paths.first).length(), 3000);
      expect(await File(paths.last).length(), 5000);
    });

    test('an older sink still gets frames', () async {
      final link = pair(newSource: true, newSink: false);
      await link.source.publish(
        peerId: 'sink',
        sessionId: 'session',
        items: [await file('notes.txt', 3000)],
      );
      final result = await link.sink
          .preparePaste(peerId: 'source', sessionId: 'session')
          .timeout(const Duration(seconds: 5));
      expect(result, RemoteClipboardPasteResult.prepared);
      expect(link.sentAsFiles, isEmpty);
      expect(link.frames, contains('clipboardData'));
      expect(await File(written.single.single).length(), 3000);
    });

    test('an older source still sends frames', () async {
      final link = pair(newSource: false, newSink: true);
      await link.source.publish(
        peerId: 'sink',
        sessionId: 'session',
        items: [await file('notes.txt', 3000)],
      );
      final result = await link.sink
          .preparePaste(peerId: 'source', sessionId: 'session')
          .timeout(const Duration(seconds: 5));
      expect(result, RemoteClipboardPasteResult.prepared);
      expect(link.frames, contains('clipboardData'));
      expect(await File(written.single.single).length(), 3000);
    });
  });

  group('a paste that waits for its files', () {
    RemoteClipboardPasteWatch watch(Object? front, {List<String>? canceled}) =>
        RemoteClipboardPasteWatch(
          download: (_) => const RemoteClipboardDownload(
            peerId: 'peer',
            names: ['big.zip'],
            totalBytes: 100,
            receivedBytes: 40,
          ),
          cancelDownload: (sessionId) async => canceled?.add(sessionId),
          foreground: () async => front,
        );

    test('pastes only into the window it was asked in', () async {
      final same = watch('finder');
      expect(
        await same.follow(
          sessionId: 's',
          pending: Future.value(RemoteClipboardPasteResult.prepared),
          front: Future.value('finder'),
        ),
        isTrue,
      );
      expect(same.current!.stage, RemoteClipboardPasteStage.pasted);

      final moved = watch('mail');
      expect(
        await moved.follow(
          sessionId: 's',
          pending: Future.value(RemoteClipboardPasteResult.prepared),
          front: Future.value('finder'),
        ),
        isFalse,
      );
      expect(moved.current!.stage, RemoteClipboardPasteStage.ready);
    });

    test(
      'files asked in a folder go into it, not wherever its window went',
      () async {
        final placedIn = <String>[];
        final w = RemoteClipboardPasteWatch(
          download: (_) => null,
          cancelDownload: (_) async {},
          // The same window, which may show another folder by now.
          foreground: () async => 'explorer',
          place: (sessionId, directory) async {
            placedIn.add(directory);
            return true;
          },
        );
        expect(
          await w.follow(
            sessionId: 's',
            pending: Future.value(RemoteClipboardPasteResult.prepared),
            front: Future.value('explorer'),
            folder: Future.value((path: '/Users/me/Desktop', name: '桌面')),
          ),
          isFalse,
        );
        expect(placedIn, ['/Users/me/Desktop']);
        expect(w.current!.stage, RemoteClipboardPasteStage.placed);
        expect(w.current!.folder, '桌面');
      },
    );

    test('two pastes of different files each go in', () async {
      var offer = 'a';
      final w = RemoteClipboardPasteWatch(
        download: (_) => null,
        cancelDownload: (_) async {},
        pasteKey: (_) => offer,
        foreground: () async => 'explorer',
      );
      final firstFiles = Completer<RemoteClipboardPasteResult>();
      final first = w.follow(
        sessionId: 's',
        pending: firstFiles.future,
        front: Future.value('explorer'),
      );
      offer = 'b';
      final second = w.follow(
        sessionId: 's',
        pending: Future.value(RemoteClipboardPasteResult.prepared),
        front: Future.value('explorer'),
      );
      expect(await second, isTrue);
      firstFiles.complete(RemoteClipboardPasteResult.prepared);
      expect(await first, isTrue);
      expect(w.pastes.map((paste) => paste.stage), [
        RemoteClipboardPasteStage.pasted,
        RemoteClipboardPasteStage.pasted,
      ]);
      w.dispose();
    });

    test('pressed again while the files come, it pastes once', () async {
      final w = watch('finder');
      final files = Completer<RemoteClipboardPasteResult>();
      final first = w.follow(
        sessionId: 's',
        pending: files.future,
        front: Future.value('finder'),
      );
      final second = w.follow(
        sessionId: 's',
        pending: files.future,
        front: Future.value('finder'),
      );
      expect(w.current!.names, ['big.zip']);
      files.complete(RemoteClipboardPasteResult.prepared);
      expect(await first, isFalse);
      expect(await second, isTrue);
    });

    test('put away, it stops the files and does not paste', () async {
      final canceled = <String>[];
      final w = watch('finder', canceled: canceled);
      final files = Completer<RemoteClipboardPasteResult>();
      final pasting = w.follow(
        sessionId: 's',
        pending: files.future,
        front: Future.value('finder'),
      );
      w.cancel();
      expect(canceled, ['s']);
      files.complete(RemoteClipboardPasteResult.failed);
      expect(await pasting, isFalse);
      expect(w.current!.stage, RemoteClipboardPasteStage.canceled);
      w.dispose();
    });
  });
}
