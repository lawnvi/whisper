import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/remote_files/fs_placement.dart';
import 'package:whisper/remote_input/remote_clipboard_paste_watch.dart';
import 'package:whisper/remote_input/remote_clipboard_paths.dart';
import 'package:whisper/remote_input/remote_clipboard_transfer.dart';
import 'package:whisper/socket/bounded_receive_queue.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';

// Offer ids are UUIDs: the sink makes a folder named after them.
const _oldOffer = '0d9f6a52-7c1e-4b5a-9f3e-2a4b6c8d0e11';
const _newOffer = '5b2e8c71-3d4f-4a6b-8c9d-0e1f2a3b4c5d';
const _offer = '9a8b7c6d-5e4f-4321-8fed-cba987654321';

TransferSnapshot _snapshot({
  required String id,
  required String peerUid,
  required FileTransferDirection direction,
  required FileTransferState state,
  String finalPath = '',
  int size = 0,
}) => TransferSnapshot(
  transferId: id,
  messageUuid: id,
  peerUid: peerUid,
  direction: direction,
  state: state,
  finalPath: finalPath,
  tempPath: '',
  size: size,
  committedBytes: state == FileTransferState.completed ? size : 0,
  lastError: '',
  updatedAt: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('retired legacy clipboard frame codes 11 and 12 are rejected', () {
    for (final code in const <int>[11, 12]) {
      expect(() => WhisperFrameType.fromCode(code), throwsFormatException);
      final encoded = WhisperFrameV3(
        type: WhisperFrameType.clipboardOffer,
        transferId: _offer,
        offset: 0,
        sequence: 0,
        payload: Uint8List(0),
      ).encode();
      encoded[5] = code;
      expect(() => WhisperFrameV3.decode(encoded), throwsFormatException);
    }
  });

  // The offer id named the folder pasted files go to, and it was taken from
  // the peer as is: `../../..` made a paired device's offer write into, and
  // on the first failed write recursively delete, any folder of this user.
  test('a peer cannot name a folder outside the clipboard folder', () async {
    final temp = await Directory.systemTemp.createTemp('whisper-escape');
    addTearDown(() => temp.delete(recursive: true));
    final root = await Directory(p.join(temp.path, 'base')).create();
    final victim = await Directory(p.join(temp.path, 'victim')).create();
    await Directory(p.join(victim.path, 'image.png')).create();
    final keep = await File(p.join(victim.path, 'keep.txt')).create();
    const binding = TransferConnectionBinding(peerId: 'source', generation: 1);
    final engine = RemoteClipboardTransferEngine(
      currentBinding: (_) => binding,
      sessionValidator:
          ({required peerId, required sessionId, required sourceIsLocal}) =>
              true,
      directoryProvider: () async => root,
      sendFrame: (_, _) async => true,
      cancelTransfer: (_) async {},
      placements: TransferPlacements(),
    );
    addTearDown(() => engine.clearSession('session'));
    WhisperFrameV3 offer(String transferId, String sessionId) => WhisperFrameV3(
      type: WhisperFrameType.clipboardOffer,
      transferId: transferId,
      offset: 0,
      sequence: 0,
      payload: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'protocolVersion': 1,
            'sessionId': sessionId,
            'items': [
              {'name': 'image.png', 'size': 1, 'kind': 'image'},
            ],
          }),
        ),
      ),
    );
    for (final (transferId, sessionId) in [
      ('../../../victim', 'session'),
      (_offer, '..'),
      (_offer, '../../victim'),
    ]) {
      await expectLater(
        engine.handleFrame(
          binding,
          offer(transferId, sessionId),
          prepareImages: true,
        ),
        throwsFormatException,
      );
      expect(
        await engine.preparePaste(peerId: 'source', sessionId: sessionId),
        RemoteClipboardPasteResult.notAvailable,
      );
    }
    expect(await keep.exists(), isTrue);
    expect(await victim.list().length, 2);
  });

  test('a failed old request cannot remove its replacement', () async {
    final root = await Directory.systemTemp.createTemp('whisper-replaced');
    final downloads = await Directory(p.join(root.path, 'dl')).create();
    const binding = TransferConnectionBinding(peerId: 'source', generation: 1);
    const channel = MethodChannel('test_replaced_clipboard');
    final oldStarted = Completer<void>();
    final newTransferId = Completer<String>();
    final oldSend = Completer<bool>();
    final placements = TransferPlacements();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => true);
    final engine = RemoteClipboardTransferEngine(
      currentBinding: (_) => binding,
      sessionValidator:
          ({required peerId, required sessionId, required sourceIsLocal}) =>
              true,
      directoryProvider: () async => root,
      writer: const DesktopClipboardFileWriter(channel: channel),
      cancelTransfer: (_) async {},
      placements: placements,
      sendFrame: (_, frame) async {
        if (frame.transferId == _oldOffer) {
          oldStarted.complete();
          return oldSend.future;
        }
        final json =
            jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
        final id = (json['transferIds'] as List).single as String;
        newTransferId.complete(id);
        return true;
      },
    );
    addTearDown(() async {
      if (!oldSend.isCompleted) oldSend.complete(false);
      await engine.clearSession('session', endsPaste: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    });
    WhisperFrameV3 offerFrame(String id) => WhisperFrameV3(
      type: WhisperFrameType.clipboardOffer,
      transferId: id,
      offset: 0,
      sequence: 0,
      payload: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'protocolVersion': 1,
            'sessionId': 'session',
            'items': [
              {'name': 'file.txt', 'size': 4, 'kind': 'file'},
            ],
          }),
        ),
      ),
    );
    await engine.handleFrame(binding, offerFrame(_oldOffer));
    final oldPaste = engine.preparePaste(
      peerId: 'source',
      sessionId: 'session',
    );
    await oldStarted.future;
    await engine.handleFrame(binding, offerFrame(_newOffer));
    final newPaste = engine.preparePaste(
      peerId: 'source',
      sessionId: 'session',
    );
    final transferId = await newTransferId.future;
    oldSend.complete(false);
    await oldPaste;
    final landed = await File(
      p.join(downloads.path, 'file.txt'),
    ).writeAsString('data');
    await placements.onTransferUpdated(
      _snapshot(
        id: transferId,
        peerUid: 'source',
        direction: FileTransferDirection.incoming,
        state: FileTransferState.completed,
        finalPath: landed.path,
        size: 4,
      ),
    );
    expect(
      await newPaste.timeout(const Duration(seconds: 2)),
      RemoteClipboardPasteResult.prepared,
    );
  });

  test(
    'screenshot transfers via private staging file, sets asImage, and cleans up staged file',
    () async {
      final root = await Directory.systemTemp.createTemp('whisper-image-queue');
      final sourcePrivate = await Directory(
        p.join(root.path, 'src-private'),
      ).create();
      final sinkPrivate = await Directory(
        p.join(root.path, 'sink-private'),
      ).create();
      final downloads = await Directory(p.join(root.path, 'dl')).create();
      final queue = BoundedReceiveQueue();
      final started = Completer<void>();
      final imageReady = Completer<void>();
      final written = Completer<List<int>>();
      final stagedPaths = <String>[];
      const channel = MethodChannel('test_image_queue_writer');
      var requestCount = 0;
      final sourcePlacements = TransferPlacements();
      final sinkPlacements = TransferPlacements();
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
        directoryProvider: () async => sourcePrivate,
        placements: sourcePlacements,
        cancelTransfer: (_) async {},
        sendFile: (peerId, path, transferId) async {
          stagedPaths.add(path);
          expect(p.isWithin(sourcePrivate.path, path), isTrue);
          expect(await File(path).exists(), isTrue);
          final landed = await File(
            path,
          ).copy(p.join(downloads.path, p.basename(path)));
          final len = await landed.length();
          unawaited(
            sinkPlacements.onTransferUpdated(
              _snapshot(
                id: transferId,
                peerUid: 'source',
                direction: FileTransferDirection.incoming,
                state: FileTransferState.completed,
                finalPath: landed.path,
                size: len,
              ),
            ),
          );
          unawaited(
            sourcePlacements.onTransferUpdated(
              _snapshot(
                id: transferId,
                peerUid: 'sink',
                direction: FileTransferDirection.outgoing,
                state: FileTransferState.completed,
                finalPath: path,
                size: len,
              ),
            ),
          );
          return true;
        },
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
        directoryProvider: () async => sinkPrivate,
        writer: const DesktopClipboardFileWriter(channel: channel),
        placements: sinkPlacements,
        cancelTransfer: (_) async {},
        sendFile: (_, _, _) async => false,
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
        await source.clearSession('session', endsPaste: true);
        await sink.clearSession('session', endsPaste: true);
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
      // Staged screenshot temp file is removed after outgoing transfer completes.
      await pumpEventQueue();
      expect(stagedPaths, hasLength(1));
      expect(await File(stagedPaths.single).exists(), isFalse);
    },
  );

  test(
    'staged screenshot files are cleaned up on cancel, session end, and startup',
    () async {
      final root = await Directory.systemTemp.createTemp('whisper-stage-clean');
      addTearDown(() => root.delete(recursive: true));
      final placements = TransferPlacements();
      final stagedPaths = <String>[];
      final sent = Completer<void>();
      final offerId = Completer<String>();
      final engine = RemoteClipboardTransferEngine(
        currentBinding: (_) =>
            const TransferConnectionBinding(peerId: 'sink', generation: 1),
        sessionValidator:
            ({required peerId, required sessionId, required sourceIsLocal}) =>
                true,
        directoryProvider: () async => root,
        placements: placements,
        cancelTransfer: (_) async {},
        sendFrame: (_, frame) async {
          if (frame.type == WhisperFrameType.clipboardOffer &&
              !offerId.isCompleted) {
            offerId.complete(frame.transferId);
          }
          return true;
        },
        sendFile: (peerId, path, transferId) async {
          stagedPaths.add(path);
          if (!sent.isCompleted) sent.complete();
          return true;
        },
      );
      final imageBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      await engine.publish(
        peerId: 'sink',
        sessionId: 'sess-1',
        items: [RemoteClipboardLocalItem.bytes('shot.png', imageBytes)],
      );
      const tid = '11111111-1111-4111-8111-111111111111';
      await engine.handleFrame(
        const TransferConnectionBinding(peerId: 'sink', generation: 1),
        WhisperFrameV3(
          type: WhisperFrameType.clipboardRequest,
          transferId: await offerId.future,
          offset: 0,
          sequence: 0,
          payload: Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'protocolVersion': 1,
                'sessionId': 'sess-1',
                'transferIds': [tid],
              }),
            ),
          ),
        ),
      );
      await sent.future.timeout(const Duration(seconds: 2));
      expect(await File(stagedPaths.single).exists(), isTrue);

      // Cancel deletes the staged file.
      await placements.onTransferUpdated(
        _snapshot(
          id: tid,
          peerUid: 'sink',
          direction: FileTransferDirection.outgoing,
          state: FileTransferState.canceled,
        ),
      );
      await pumpEventQueue();
      expect(await File(stagedPaths.single).exists(), isFalse);

      // Session end with endsPaste deletes an in-flight staged file.
      final sent2 = Completer<void>();
      final offerId2 = Completer<String>();
      final engineEnd = RemoteClipboardTransferEngine(
        currentBinding: (_) =>
            const TransferConnectionBinding(peerId: 'sink', generation: 1),
        sessionValidator:
            ({required peerId, required sessionId, required sourceIsLocal}) =>
                true,
        directoryProvider: () async => root,
        placements: placements,
        cancelTransfer: (_) async {},
        sendFrame: (_, frame) async {
          if (frame.type == WhisperFrameType.clipboardOffer &&
              !offerId2.isCompleted) {
            offerId2.complete(frame.transferId);
          }
          return true;
        },
        sendFile: (peerId, path, transferId) async {
          stagedPaths.add(path);
          if (!sent2.isCompleted) sent2.complete();
          return true;
        },
      );
      await engineEnd.publish(
        peerId: 'sink',
        sessionId: 'sess-2',
        items: [RemoteClipboardLocalItem.bytes('shot2.png', imageBytes)],
      );
      const tid2 = '33333333-3333-4333-8333-333333333333';
      await engineEnd.handleFrame(
        const TransferConnectionBinding(peerId: 'sink', generation: 1),
        WhisperFrameV3(
          type: WhisperFrameType.clipboardRequest,
          transferId: await offerId2.future,
          offset: 0,
          sequence: 0,
          payload: Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'protocolVersion': 1,
                'sessionId': 'sess-2',
                'transferIds': [tid2],
              }),
            ),
          ),
        ),
      );
      await sent2.future.timeout(const Duration(seconds: 2));
      expect(await File(stagedPaths.last).exists(), isTrue);
      await engineEnd.clearSession('sess-2', endsPaste: true);
      expect(await File(stagedPaths.last).exists(), isFalse);

      // Leftover staging/cache directories from a crash are wiped on startup.
      final crashStaging = remoteClipboardStagingDirectory(
        root.path,
        '22222222-2222-4222-8222-222222222222',
      );
      await crashStaging.create(recursive: true);
      final staleShot = await File(
        p.join(crashStaging.path, 'secret.png'),
      ).writeAsBytes(imageBytes);
      expect(await staleShot.exists(), isTrue);

      await engine.cleanupStaleDirectories();
      expect(await staleShot.exists(), isFalse);
      expect(await crashStaging.exists(), isFalse);
    },
  );

  test(
    'a local copy cancels a pending image without writing stale data',
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
        placements: TransferPlacements(),
        cancelTransfer: (_) async {},
        sendFrame: (_, frame) async {
          sent.add(frame.type);
          return true;
        },
      );
      addTearDown(() async {
        if (!resume.isCompleted) resume.complete();
        await engine.clearSession('session', endsPaste: true);
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
          transferId: _offer,
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
      expect(
        engine.remoteOffer(peerId: 'source', sessionId: 'session'),
        isNull,
      );
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
              size: remoteClipboardTransferMaxFileBytes + 1,
              openRead: () => const Stream<List<int>>.empty(),
            ),
          ],
        ),
        isFalse,
      );
      expect(sent, isNot(contains(WhisperFrameType.clipboardOffer)));
    },
  );

  test(
    'relays a controlled-device screenshot over file transfers only after target pastes',
    () async {
      final root = await Directory.systemTemp.createTemp('whisper-clip-relay');
      final originRoot = await Directory(p.join(root.path, 'origin')).create();
      final brokerRoot = await Directory(p.join(root.path, 'broker')).create();
      final targetRoot = await Directory(p.join(root.path, 'target')).create();
      final dlBroker = await Directory(p.join(root.path, 'dl-broker')).create();
      final dlTarget = await Directory(p.join(root.path, 'dl-target')).create();
      const writerChannel = MethodChannel('test_workspace_clipboard_writer');
      final writtenPaths = <String>[];
      var writtenAsImage = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(writerChannel, (call) async {
            writtenPaths.addAll(
              List<String>.from((call.arguments as Map)['paths'] as List),
            );
            writtenAsImage = (call.arguments as Map)['asImage'] == true;
            return true;
          });
      final originPlacements = TransferPlacements();
      final brokerPlacements = TransferPlacements();
      final targetPlacements = TransferPlacements();
      late RemoteClipboardTransferEngine origin;
      late RemoteClipboardTransferEngine broker;
      late RemoteClipboardTransferEngine target;
      final originFrames = <WhisperFrameType>[];
      final originSentFiles = <String>[];

      origin = RemoteClipboardTransferEngine(
        currentBinding: (peerId) => peerId == 'broker'
            ? const TransferConnectionBinding(peerId: 'broker', generation: 1)
            : null,
        sessionValidator:
            ({required peerId, required sessionId, required sourceIsLocal}) =>
                peerId == 'broker' && sessionId == 'origin-session',
        directoryProvider: () async => originRoot,
        placements: originPlacements,
        cancelTransfer: (_) async {},
        sendFile: (peerId, path, transferId) async {
          originSentFiles.add(transferId);
          final landed = await File(
            path,
          ).copy(p.join(dlBroker.path, p.basename(path)));
          final len = await landed.length();
          unawaited(
            brokerPlacements.onTransferUpdated(
              _snapshot(
                id: transferId,
                peerUid: 'origin',
                direction: FileTransferDirection.incoming,
                state: FileTransferState.completed,
                finalPath: landed.path,
                size: len,
              ),
            ),
          );
          unawaited(
            originPlacements.onTransferUpdated(
              _snapshot(
                id: transferId,
                peerUid: 'broker',
                direction: FileTransferDirection.outgoing,
                state: FileTransferState.completed,
                finalPath: path,
                size: len,
              ),
            ),
          );
          return true;
        },
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
        directoryProvider: () async => brokerRoot,
        placements: brokerPlacements,
        cancelTransfer: (_) async {},
        sendFile: (peerId, path, transferId) async {
          final landed = await File(
            path,
          ).copy(p.join(dlTarget.path, p.basename(path)));
          final len = await landed.length();
          unawaited(
            targetPlacements.onTransferUpdated(
              _snapshot(
                id: transferId,
                peerUid: 'broker',
                direction: FileTransferDirection.incoming,
                state: FileTransferState.completed,
                finalPath: landed.path,
                size: len,
              ),
            ),
          );
          return true;
        },
        sendFrame: (binding, frame) async {
          if (binding.peerId == 'origin') {
            unawaited(
              origin.handleFrame(
                const TransferConnectionBinding(
                  peerId: 'broker',
                  generation: 1,
                ),
                frame,
              ),
            );
          } else if (binding.peerId == 'target') {
            await target.handleFrame(
              const TransferConnectionBinding(peerId: 'broker', generation: 1),
              frame,
            );
          }
          return true;
        },
      );
      target = RemoteClipboardTransferEngine(
        currentBinding: (peerId) => peerId == 'broker'
            ? const TransferConnectionBinding(peerId: 'broker', generation: 1)
            : null,
        sessionValidator:
            ({required peerId, required sessionId, required sourceIsLocal}) =>
                peerId == 'broker' && sessionId == 'target-session',
        directoryProvider: () async => targetRoot,
        writer: const DesktopClipboardFileWriter(channel: writerChannel),
        placements: targetPlacements,
        cancelTransfer: (_) async {},
        sendFile: (_, _, _) async => false,
        sendFrame: (binding, frame) async {
          unawaited(
            broker.handleFrame(
              const TransferConnectionBinding(peerId: 'target', generation: 1),
              frame,
            ),
          );
          return true;
        },
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
      expect(originSentFiles, isEmpty);
      expect(
        await broker.relayRemoteOffer(
          originPeerId: 'origin',
          originSessionId: 'origin-session',
          targetPeerId: 'target',
          targetSessionId: 'target-session',
        ),
        isTrue,
      );
      expect(originSentFiles, isEmpty);

      expect(
        await target
            .preparePaste(peerId: 'broker', sessionId: 'target-session')
            .timeout(const Duration(seconds: 3)),
        RemoteClipboardPasteResult.prepared,
      );
      expect(originSentFiles, hasLength(1));
      expect(writtenAsImage, isTrue);
      expect(await File(writtenPaths.single).readAsBytes(), bytes);

      await broker.clearSession('origin-session', endsPaste: true);
      await target.clearSession('target-session', endsPaste: true);
      await root.delete(recursive: true);
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

    ({
      RemoteClipboardTransferEngine source,
      RemoteClipboardTransferEngine sink,
      List<String> frames,
      List<String> sentAsFiles,
    })
    pair({Future<void>? landAfter}) {
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
        directoryProvider: () async => root,
        sendFrame: (_, frame) async {
          frames.add(frame.type.name);
          await sink.handleFrame(toSource, frame);
          return true;
        },
        sendFile: (peerId, path, transferId) async {
          sentAsFiles.add(transferId);
          await landAfter;
          final landed = await File(
            path,
          ).copy('${downloads.path}/${path.split('/').last}');
          unawaited(
            placements.onTransferUpdated(
              _snapshot(
                id: transferId,
                peerUid: 'source',
                direction: FileTransferDirection.incoming,
                state: FileTransferState.completed,
                finalPath: landed.path,
                size: await landed.length(),
              ),
            ),
          );
          return true;
        },
        cancelTransfer: (_) async {},
        placements: TransferPlacements(),
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
        sendFile: (_, _, _) async => false,
        cancelTransfer: (_) async {},
        placements: placements,
      );
      return (
        source: source,
        sink: sink,
        frames: frames,
        sentAsFiles: sentAsFiles,
      );
    }

    Future<void> untilSent(List<String> sentAsFiles, int count) async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (sentAsFiles.length < count && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(sentAsFiles, hasLength(count));
    }

    test(
      'copied over while its files come, the paste still gets them',
      () async {
        final land = Completer<void>();
        final link = pair(landAfter: land.future);
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
        await untilSent(link.sentAsFiles, 1);
        await link.sink.clearSession('s');
        await link.source.clearSession('s', notifyPeer: true, peerId: 'sink');
        land.complete();
        expect(await pasting, RemoteClipboardPasteResult.prepared);
        expect(written.single.single, endsWith('report.pdf'));
        expect(link.sink.ownsClipboardPaths('s', written.single), isTrue);
      },
    );

    test('put into a folder, nothing there is overwritten', () async {
      final link = pair();
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
      final link = pair(landAfter: land.future);
      final first = await file('first.bin', 3000);
      await link.source.publish(peerId: 'sink', sessionId: 's', items: [first]);
      final pastingFirst = link.sink.preparePaste(
        peerId: 'source',
        sessionId: 's',
      );
      await untilSent(link.sentAsFiles, 1);
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
      await untilSent(link.sentAsFiles, 2);
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
      final link = pair(landAfter: land.future);
      final item = await file('report.pdf', 3000);
      await link.source.publish(peerId: 'sink', sessionId: 's', items: [item]);
      final pasting = link.sink.preparePaste(peerId: 'source', sessionId: 's');
      await untilSent(link.sentAsFiles, 1);
      await link.sink.clearSession('s', endsPaste: true);
      land.complete();
      expect(await pasting, isNot(RemoteClipboardPasteResult.prepared));
      expect(written, isEmpty);
    });

    test('files and large offers come as transfers, on paste only', () async {
      final link = pair();
      final big = RemoteClipboardLocalItem(
        name: 'big.bin',
        size: 128 * 1024 * 1024,
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
      expect(link.frames, ['clipboardOffer']);
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
      final paths = written.single;
      expect(paths.map((path) => path.split('/').last), [
        'notes.txt',
        'photo.jpg',
      ]);
      expect(await File(paths.first).length(), 3000);
      expect(await File(paths.last).length(), 5000);
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
