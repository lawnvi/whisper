import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/file_path_policy.dart';
import 'package:whisper/socket/file_transfer_engine.dart';
import 'package:whisper/socket/file_transfer_source.dart';
import 'package:whisper/socket/file_transfer_v3.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/transfer_ack_watchdog.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';
import 'package:whisper/socket/wire_input_policy.dart';
import 'package:whisper/socket/wire_message_codec.dart';
import 'package:whisper/socket/wire_message_replay.dart';
import 'package:whisper/state/peer_profile.dart';

const _binding = TransferConnectionBinding(peerId: 'peer-a', generation: 7);
const _replacementBinding = TransferConnectionBinding(
  peerId: 'peer-a',
  generation: 8,
);
const _peerBBinding = TransferConnectionBinding(
  peerId: 'peer-b',
  generation: 41,
);
const _firstId = '01234567-89ab-4cde-8fab-0123456789ab';
const _secondId = '11234567-89ab-4cde-8fab-0123456789ab';
const _thirdId = '21234567-89ab-4cde-8fab-0123456789ab';
const _fourthId = '31234567-89ab-4cde-8fab-0123456789ab';
const _fifthId = '41234567-89ab-4cde-8fab-0123456789ab';
const _sixthId = '51234567-89ab-4cde-8fab-0123456789ab';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'ACK validates durable and actual-sent boundaries before mutation',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      const size = fileTransferV3WindowSize + 1;
      await _persistOutgoing(database, _firstId, size: size);
      final sent = <WhisperFrameV3>[];
      final scheduler = _FakeTimerScheduler();
      final watchdog = TransferAckWatchdog(timerFactory: scheduler.createTimer);
      final engine = _engine(
        database,
        sent,
        ackWatchdog: watchdog,
        sourceFactory: (_, expectedSize) => _SizedSource(expectedSize),
      );

      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(FileTransferV3Action.ready, _firstId, size: size, offset: 0),
        ),
        requireCurrent: () {},
      );
      final firstWindow = watchdog.currentWindow(_firstId)!;
      expect(firstWindow.sentEnd, fileTransferV3WindowSize);

      await expectLater(
        engine.handleFrame(
          _binding,
          _controlFrame(
            _control(
              FileTransferV3Action.ack,
              _firstId,
              size: size,
              offset: size,
            ),
          ),
          requireCurrent: () {},
        ),
        throwsA(
          isA<WireInputRejected>().having(
            (error) => error.reason,
            'reason',
            WireInputReason.transferOffsetInvalid,
          ),
        ),
      );
      expect((await database.fetchFileTransfer(_firstId))?.committedBytes, 0);
      expect(watchdog.currentWindow(_firstId), firstWindow);

      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(FileTransferV3Action.ack, _firstId, size: size, offset: 0),
        ),
        requireCurrent: () {},
      );
      expect(watchdog.currentWindow(_firstId)?.attempt, 1);

      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(
            FileTransferV3Action.ack,
            _firstId,
            size: size,
            offset: fileTransferV3WindowSize,
          ),
        ),
        requireCurrent: () {},
      );
      expect(watchdog.currentWindow(_firstId)?.sentEnd, size);
      expect(
        (await database.fetchFileTransfer(_firstId))?.committedBytes,
        fileTransferV3WindowSize,
      );
      final secondWindow = watchdog.currentWindow(_firstId)!;

      await expectLater(
        engine.handleFrame(
          _binding,
          _controlFrame(
            _control(
              FileTransferV3Action.ack,
              _firstId,
              size: size,
              offset: fileTransferV3WindowSize - 1,
            ),
          ),
          requireCurrent: () {},
        ),
        throwsA(
          isA<WireInputRejected>().having(
            (error) => error.reason,
            'reason',
            WireInputReason.transferOffsetInvalid,
          ),
        ),
      );
      expect(watchdog.currentWindow(_firstId), secondWindow);
      expect(
        (await database.fetchFileTransfer(_firstId))?.committedBytes,
        fileTransferV3WindowSize,
      );

      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(
            FileTransferV3Action.ack,
            _firstId,
            size: size,
            offset: size,
          ),
        ),
        requireCurrent: () {},
      );
      expect(watchdog.currentWindow(_firstId), isNull);
      expect(
        (await database.fetchFileTransfer(_firstId))?.committedBytes,
        size,
      );
    },
  );

  test(
    'duplicate READY at the current offset preserves the in-flight window',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await _persistOutgoing(database, _firstId, size: 4);
      final sent = <WhisperFrameV3>[];
      final scheduler = _FakeTimerScheduler();
      final watchdog = TransferAckWatchdog(timerFactory: scheduler.createTimer);
      final engine = _engine(
        database,
        sent,
        ackWatchdog: watchdog,
        sourceFactory: (_, expectedSize) => _SizedSource(expectedSize),
      );
      final ready = _controlFrame(
        _control(FileTransferV3Action.ready, _firstId, size: 4, offset: 0),
      );
      await engine.handleFrame(_binding, ready, requireCurrent: () {});
      final window = watchdog.currentWindow(_firstId)!;
      final dataBeforeDuplicate = _dataFrames(sent, _firstId).toList();

      await engine.handleFrame(_binding, ready, requireCurrent: () {});

      expect(watchdog.currentWindow(_firstId), same(window));
      expect(_dataFrames(sent, _firstId), dataBeforeDuplicate);
      expect((await database.fetchFileTransfer(_firstId))?.committedBytes, 0);
    },
  );

  test(
    'delayed READY below committed progress cannot rewind active transfer',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await _persistOutgoing(database, _firstId, size: 4);
      final sent = <WhisperFrameV3>[];
      final scheduler = _FakeTimerScheduler();
      final watchdog = TransferAckWatchdog(timerFactory: scheduler.createTimer);
      final engine = _engine(
        database,
        sent,
        ackWatchdog: watchdog,
        sourceFactory: (_, expectedSize) => _SizedSource(expectedSize),
      );
      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(FileTransferV3Action.ready, _firstId, size: 4, offset: 0),
        ),
        requireCurrent: () {},
      );
      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(FileTransferV3Action.ack, _firstId, size: 4, offset: 2),
        ),
        requireCurrent: () {},
      );
      final window = watchdog.currentWindow(_firstId)!;
      final dataBeforeDelayedReady = _dataFrames(sent, _firstId).toList();

      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(FileTransferV3Action.ready, _firstId, size: 4, offset: 0),
        ),
        requireCurrent: () {},
      );

      expect(watchdog.currentWindow(_firstId), same(window));
      expect(_dataFrames(sent, _firstId), dataBeforeDelayedReady);
      expect((await database.fetchFileTransfer(_firstId))?.committedBytes, 2);
    },
  );

  test(
    'ACK from another connection generation cannot cancel the window',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await _persistOutgoing(database, _firstId, size: 4);
      final sent = <WhisperFrameV3>[];
      final watchdog = TransferAckWatchdog(
        timerFactory: _FakeTimerScheduler().createTimer,
      );
      final engine = _engine(
        database,
        sent,
        ackWatchdog: watchdog,
        sourceFactory: (_, expectedSize) => _SizedSource(expectedSize),
      );
      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(FileTransferV3Action.ready, _firstId, size: 4, offset: 0),
        ),
        requireCurrent: () {},
      );
      final window = watchdog.currentWindow(_firstId)!;

      await expectLater(
        engine.handleFrame(
          const TransferConnectionBinding(peerId: 'peer-a', generation: 8),
          _controlFrame(
            _control(FileTransferV3Action.ack, _firstId, size: 4, offset: 4),
          ),
          requireCurrent: () {},
        ),
        throwsA(
          isA<WireInputRejected>().having(
            (error) => error.reason,
            'reason',
            WireInputReason.sessionNotCurrent,
          ),
        ),
      );
      expect(watchdog.currentWindow(_firstId), window);
      expect((await database.fetchFileTransfer(_firstId))?.committedBytes, 0);
    },
  );

  test(
    'watchdog retransmits two durable windows then removes one generation',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await _persistOutgoing(database, _firstId, size: 4);
      final sent = <WhisperFrameV3>[];
      final scheduler = _FakeTimerScheduler();
      final unresponsive = <TransferConnectionBinding>[];
      final engine = _engine(
        database,
        sent,
        ackWatchdog: TransferAckWatchdog(timerFactory: scheduler.createTimer),
        sourceFactory: (_, expectedSize) => _SizedSource(expectedSize),
        markPeerUnresponsive: (binding) {
          unresponsive.add(binding);
          return true;
        },
      );
      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(FileTransferV3Action.ready, _firstId, size: 4, offset: 0),
        ),
        requireCurrent: () {},
      );

      await scheduler.fireNext();
      await scheduler.fireNext();
      await scheduler.fireNext();

      final data = _dataFrames(sent, _firstId).toList();
      expect(data.map((frame) => frame.offset), <int>[0, 0, 0]);
      expect(data.map((frame) => frame.sequence), <int>[0, 1, 2]);
      expect(unresponsive, <TransferConnectionBinding>[_binding]);
    },
  );

  test(
    'duplicate committed receiver data only re-ACKs durable progress',
    () async {
      final root = await Directory.systemTemp.createTemp('whisper-duplicate-');
      addTearDown(() => root.delete(recursive: true));
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final fullBytes = Uint8List.fromList(const <int>[1, 2, 3, 4, 5, 6, 7, 8]);
      final offer = _incomingMessage(
        _firstId,
        size: fullBytes.length,
        checksum: bytesChecksum(fullBytes, algorithm: 'sha256'),
      );
      final message = await database.insertMessageReturning(offer);
      final temp = File(await safeTransferTempPath(root, _firstId));
      await temp.parent.create(recursive: true);
      await temp.writeAsBytes(fullBytes.sublist(0, 4));
      await database.upsertFileTransfer(
        _incomingTransfer(
          _firstId,
          size: fullBytes.length,
          messageRowId: message.id,
          tempPath: temp.path,
          committedBytes: 4,
          checksum: bytesChecksum(fullBytes, algorithm: 'sha256'),
        ),
      );
      final sent = <WhisperFrameV3>[];
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
      );
      await engine.handleFrame(
        _binding,
        _offerFrame(offer),
        requireCurrent: () {},
      );
      sent.clear();

      await engine.handleFrame(
        _binding,
        WhisperFrameV3(
          type: WhisperFrameType.fileData,
          transferId: _firstId,
          offset: 0,
          sequence: 0,
          payload: Uint8List.fromList(fullBytes.sublist(0, 4)),
        ),
        requireCurrent: () {},
      );

      expect(await temp.readAsBytes(), fullBytes.sublist(0, 4));
      expect((await database.fetchFileTransfer(_firstId))?.committedBytes, 4);
      final ack = FileTransferV3Control.fromJson(
        jsonDecode(utf8.decode(sent.single.payload)) as Map<String, dynamic>,
      );
      expect(ack.action, FileTransferV3Action.ack);
      expect(ack.durableOffset, 4);
    },
  );

  test(
    'local active cancel skips a canceled queued id and starts one successor',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      for (final id in <String>[_firstId, _secondId, _thirdId]) {
        await _persistOutgoing(database, id, size: 1);
      }
      final sent = <WhisperFrameV3>[];
      final engine = _engine(
        database,
        sent,
        sourceFactory: (_, expectedSize) => _SizedSource(expectedSize),
      );
      for (final id in <String>[_firstId, _secondId, _thirdId]) {
        await engine.handleFrame(
          _binding,
          _controlFrame(
            _control(FileTransferV3Action.ready, id, size: 1, offset: 0),
          ),
          requireCurrent: () {},
        );
      }
      expect(_dataFrames(sent, _firstId), hasLength(1));
      expect(_dataFrames(sent, _secondId), isEmpty);
      expect(_dataFrames(sent, _thirdId), isEmpty);

      await engine.cancelTransfer(_secondId);
      await engine.cancelTransfer(_firstId);

      expect(_dataFrames(sent, _secondId), isEmpty);
      expect(_dataFrames(sent, _thirdId), hasLength(1));
      expect(
        (await database.fetchFileTransfer(_firstId))?.state,
        FileTransferState.canceled,
      );
      expect(
        (await database.fetchFileTransfer(_secondId))?.state,
        FileTransferState.canceled,
      );
      expect(
        (await database.fetchFileTransfer(_thirdId))?.state,
        FileTransferState.transferring,
      );
    },
  );

  for (final action in <FileTransferV3Action>[
    FileTransferV3Action.complete,
    FileTransferV3Action.cancel,
    FileTransferV3Action.error,
  ]) {
    test(
      'remote $action releases once and starts one outgoing successor',
      () async {
        final database = LocalDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        for (final id in <String>[_firstId, _secondId]) {
          await _persistOutgoing(database, id, size: 1);
        }
        final sent = <WhisperFrameV3>[];
        final engine = _engine(
          database,
          sent,
          sourceFactory: (_, expectedSize) => _SizedSource(expectedSize),
        );
        for (final id in <String>[_firstId, _secondId]) {
          await engine.handleFrame(
            _binding,
            _controlFrame(
              _control(FileTransferV3Action.ready, id, size: 1, offset: 0),
            ),
            requireCurrent: () {},
          );
        }

        final terminal = _control(
          action,
          _firstId,
          size: 1,
          offset: action == FileTransferV3Action.complete ? 1 : 0,
        );
        await engine.handleFrame(
          _binding,
          _controlFrame(terminal),
          requireCurrent: () {},
        );
        await engine.handleFrame(
          _binding,
          _controlFrame(terminal),
          requireCurrent: () {},
        );

        expect(_dataFrames(sent, _secondId), hasLength(1));
        expect(
          (await database.fetchFileTransfer(_secondId))?.state,
          FileTransferState.transferring,
        );
        if (action == FileTransferV3Action.cancel) {
          expect(
            (await database.fetchFileTransfer(_firstId))?.state,
            FileTransferState.paused,
          );
        }
      },
    );
  }

  test('receiver cancel pauses outgoing so the sender can reoffer', () async {
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await _persistOutgoing(database, _firstId, size: 1);
    final sent = <WhisperFrameV3>[];
    final engine = _engine(
      database,
      sent,
      sourceFactory: (_, expectedSize) => _SizedSource(expectedSize),
    );
    await engine.handleFrame(
      _binding,
      _controlFrame(
        _control(FileTransferV3Action.ready, _firstId, size: 1, offset: 0),
      ),
      requireCurrent: () {},
    );
    await engine.handleFrame(
      _binding,
      _controlFrame(
        _control(FileTransferV3Action.cancel, _firstId, size: 1, offset: 0),
      ),
      requireCurrent: () {},
    );

    expect(
      (await database.fetchFileTransfer(_firstId))?.state,
      FileTransferState.paused,
    );

    sent.clear();
    await engine.retryTransfer(_firstId);

    expect(
      sent.where((frame) => frame.type == WhisperFrameType.fileOffer),
      hasLength(1),
    );
    expect(
      (await database.fetchFileTransfer(_firstId))?.state,
      FileTransferState.negotiating,
    );
  });

  test(
    'queued successor accepts a 2 MiB ACK while its window is still sending',
    () async {
      const successorSize = fileTransferV3AckIntervalSize + 1;
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await _persistOutgoing(database, _firstId, size: 1);
      await _persistOutgoing(database, _secondId, size: successorSize);
      final sent = <WhisperFrameV3>[];
      final scheduler = _FakeTimerScheduler();
      final watchdog = TransferAckWatchdog(timerFactory: scheduler.createTimer);
      Future<Object?>? ackResult;
      late final FileTransferEngine engine;
      engine = _engine(
        database,
        sent,
        ackWatchdog: watchdog,
        sourceFactory: (_, expectedSize) => _SizedSource(expectedSize),
        sendBytesToConnection: (_, frame) {
          if (frame.type == WhisperFrameType.fileData &&
              frame.transferId == _secondId &&
              frame.offset + frame.payload.length ==
                  fileTransferV3AckIntervalSize &&
              ackResult == null) {
            ackResult = Future<void>.delayed(Duration.zero).then<Object?>((
              _,
            ) async {
              try {
                await engine.handleFrame(
                  _binding,
                  _controlFrame(
                    _control(
                      FileTransferV3Action.ack,
                      _secondId,
                      size: successorSize,
                      offset: fileTransferV3AckIntervalSize,
                    ),
                  ),
                  requireCurrent: () {},
                );
                return null;
              } catch (error) {
                return error;
              }
            });
          }
          return true;
        },
      );
      for (final entry in <(String, int)>[
        (_firstId, 1),
        (_secondId, successorSize),
      ]) {
        await engine.handleFrame(
          _binding,
          _controlFrame(
            _control(
              FileTransferV3Action.ready,
              entry.$1,
              size: entry.$2,
              offset: 0,
            ),
          ),
          requireCurrent: () {},
        );
      }

      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(FileTransferV3Action.complete, _firstId, size: 1, offset: 1),
        ),
        requireCurrent: () {},
      );

      expect(ackResult, isNotNull);
      expect(await ackResult!.timeout(const Duration(seconds: 1)), isNull);
      final successorData = _dataFrames(sent, _secondId).toList();
      expect(successorData.map((frame) => frame.offset), <int>[
        0,
        fileTransferV3FramePayloadSize,
        fileTransferV3FramePayloadSize * 2,
        fileTransferV3FramePayloadSize * 3,
        fileTransferV3AckIntervalSize,
      ]);
      expect(successorData.map((frame) => frame.sequence), <int>[
        0,
        1,
        2,
        3,
        4,
      ]);
      expect(
        (await database.fetchFileTransfer(_secondId))?.committedBytes,
        fileTransferV3AckIntervalSize,
      );
      expect(
        watchdog.currentWindow(_secondId)?.durableOffset,
        fileTransferV3AckIntervalSize,
      );
      expect(watchdog.currentWindow(_secondId)?.sentEnd, successorSize);
    },
  );

  test(
    'source read throw releases active and starts its queued successor',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      for (final id in <String>[_firstId, _secondId]) {
        await _persistOutgoing(database, id, size: 1);
      }
      final readStarted = Completer<void>();
      final releaseRead = Completer<void>();
      final sent = <WhisperFrameV3>[];
      final engine = _engine(
        database,
        sent,
        sourceFactory: (path, expectedSize) => path.endsWith(_firstId)
            ? _GatedFailingSource(
                expectedSize,
                readStarted: readStarted,
                releaseRead: releaseRead,
              )
            : _SizedSource(expectedSize),
      );

      final firstReady = engine.handleFrame(
        _binding,
        _controlFrame(
          _control(FileTransferV3Action.ready, _firstId, size: 1, offset: 0),
        ),
        requireCurrent: () {},
      );
      await readStarted.future;
      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(FileTransferV3Action.ready, _secondId, size: 1, offset: 0),
        ),
        requireCurrent: () {},
      );
      releaseRead.complete();
      await firstReady;

      expect(
        (await database.fetchFileTransfer(_firstId))?.state,
        FileTransferState.failed,
      );
      expect(_dataFrames(sent, _secondId), hasLength(1));
    },
  );

  for (final throws in <bool>[false, true]) {
    test(
      'generation-bound send ${throws ? 'throw' : 'false'} progresses queue',
      () async {
        final database = LocalDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        for (final id in <String>[_firstId, _secondId]) {
          await _persistOutgoing(database, id, size: 1);
        }
        final sendStarted = Completer<void>();
        final releaseSend = Completer<void>();
        final sent = <WhisperFrameV3>[];
        var faulted = false;
        final engine = _engine(
          database,
          sent,
          sourceFactory: (_, expectedSize) => _SizedSource(expectedSize),
          sendBytesToConnection: (binding, frame) async {
            if (frame.type == WhisperFrameType.fileData &&
                frame.transferId == _firstId &&
                !faulted) {
              faulted = true;
              sendStarted.complete();
              await releaseSend.future;
              if (throws) {
                throw StateError('injected send failure');
              }
              return false;
            }
            return true;
          },
        );

        final firstReady = engine.handleFrame(
          _binding,
          _controlFrame(
            _control(FileTransferV3Action.ready, _firstId, size: 1, offset: 0),
          ),
          requireCurrent: () {},
        );
        await sendStarted.future;
        await engine.handleFrame(
          _binding,
          _controlFrame(
            _control(FileTransferV3Action.ready, _secondId, size: 1, offset: 0),
          ),
          requireCurrent: () {},
        );
        releaseSend.complete();
        await firstReady;

        expect(
          (await database.fetchFileTransfer(_firstId))?.state,
          FileTransferState.failed,
        );
        expect(_dataFrames(sent, _secondId), hasLength(1));
      },
    );
  }

  test(
    'incoming progression uses the matching generation for each peer',
    () async {
      final root = await Directory.systemTemp.createTemp('whisper-cross-peer-');
      addTearDown(() => root.delete(recursive: true));
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final sent = <WhisperFrameV3>[];
      final routed =
          <({TransferConnectionBinding connection, WhisperFrameV3 frame})>[];
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
        currentConnectionBinding: (peerId) => switch (peerId) {
          'peer-a' => _binding,
          'peer-b' => _peerBBinding,
          _ => null,
        },
        connectedPeerIds: () => const <String>{'peer-a', 'peer-b'},
        remoteProfileFor: (peerId) => _capablePeer(peerId),
        sendBytesToConnection: (connection, frame) {
          routed.add((connection: connection, frame: frame));
          return true;
        },
      );
      final checksum = bytesChecksum(const <int>[1], algorithm: 'sha256');
      await engine.handleFrame(
        _binding,
        _offerFrame(_incomingMessage(_firstId, size: 1, checksum: checksum)),
        requireCurrent: () {},
      );
      final peerBMessage = await database.insertMessageReturning(
        _incomingMessage(
          _secondId,
          size: 1,
          checksum: checksum,
          peerId: 'peer-b',
        ),
      );
      await database.upsertFileTransfer(
        _incomingTransfer(
          _secondId,
          size: 1,
          messageRowId: peerBMessage.id,
          tempPath: await safeTransferTempPath(root, _secondId),
          committedBytes: 0,
          checksum: checksum,
          peerId: 'peer-b',
        ).copyWith(state: FileTransferState.queued),
      );
      routed.clear();

      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(FileTransferV3Action.cancel, _firstId, size: 1, offset: 0),
        ),
        requireCurrent: () {},
      );

      final peerBReady = routed
          .where(
            (send) =>
                send.frame.type == WhisperFrameType.fileReady &&
                send.frame.transferId == _secondId,
          )
          .toList();
      expect(peerBReady, hasLength(1));
      expect(peerBReady.single.connection, _peerBBinding);
    },
  );

  test(
    'false READY releases stale generation and advances each successor once',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'whisper-stale-ready-',
      );
      addTearDown(() => root.delete(recursive: true));
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final sent = <WhisperFrameV3>[];
      final routed =
          <({TransferConnectionBinding connection, WhisperFrameV3 frame})>[];
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
        currentConnectionBinding: (_) => _replacementBinding,
        sendBytesToConnection: (connection, frame) {
          routed.add((connection: connection, frame: frame));
          return frame.type != WhisperFrameType.fileReady ||
              frame.transferId == _firstId ||
              connection != _binding;
        },
      );
      final checksum = bytesChecksum(const <int>[1], algorithm: 'sha256');
      for (final id in <String>[_firstId, _secondId, _thirdId]) {
        await engine.handleFrame(
          _binding,
          _offerFrame(_incomingMessage(id, size: 1, checksum: checksum)),
          requireCurrent: () {},
        );
      }
      sent.clear();

      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(FileTransferV3Action.cancel, _firstId, size: 1, offset: 0),
        ),
        requireCurrent: () {},
      );

      expect(_readyFrames(sent, _secondId), hasLength(1));
      expect(_readyFrames(sent, _thirdId), hasLength(1));
      expect(
        routed
            .singleWhere((send) => send.frame.transferId == _secondId)
            .connection,
        _binding,
      );
      expect(
        routed
            .singleWhere((send) => send.frame.transferId == _thirdId)
            .connection,
        _replacementBinding,
      );
      expect(
        (await database.fetchFileTransfer(_secondId))?.state,
        FileTransferState.waitingReconnect,
      );
      expect(
        (await database.fetchFileTransfer(_thirdId))?.state,
        FileTransferState.negotiating,
      );
    },
  );

  test('initial false READY is not retried recursively', () async {
    final root = await Directory.systemTemp.createTemp('whisper-ready-once-');
    addTearDown(() => root.delete(recursive: true));
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    var readyAttempts = 0;
    final engine = _engine(
      database,
      <WhisperFrameV3>[],
      downloadDirectory: () async => root,
      sendBytesToConnection: (connection, frame) {
        if (frame.type != WhisperFrameType.fileReady) {
          return true;
        }
        readyAttempts++;
        return readyAttempts > 1;
      },
    );
    final checksum = bytesChecksum(const <int>[1], algorithm: 'sha256');

    await engine.handleFrame(
      _binding,
      _offerFrame(_incomingMessage(_firstId, size: 1, checksum: checksum)),
      requireCurrent: () {},
    );

    expect(readyAttempts, 1);
    expect(
      (await database.fetchFileTransfer(_firstId))?.state,
      FileTransferState.waitingReconnect,
    );
  });

  for (final action in <FileTransferV3Action>[
    FileTransferV3Action.cancel,
    FileTransferV3Action.error,
  ]) {
    test(
      'remote $action releases once and starts one incoming successor',
      () async {
        final root = await Directory.systemTemp.createTemp('whisper-incoming-');
        addTearDown(() => root.delete(recursive: true));
        final database = LocalDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        final sent = <WhisperFrameV3>[];
        final engine = _engine(
          database,
          sent,
          downloadDirectory: () async => root,
        );
        final checksum = bytesChecksum(const <int>[1], algorithm: 'sha256');
        for (final id in <String>[_firstId, _secondId]) {
          await engine.handleFrame(
            _binding,
            _offerFrame(_incomingMessage(id, size: 1, checksum: checksum)),
            requireCurrent: () {},
          );
        }

        final terminal = _control(action, _firstId, size: 1, offset: 0);
        await engine.handleFrame(
          _binding,
          _controlFrame(terminal),
          requireCurrent: () {},
        );
        await engine.handleFrame(
          _binding,
          _controlFrame(terminal),
          requireCurrent: () {},
        );

        expect(_readyFrames(sent, _secondId), hasLength(1));
      },
    );
  }

  test(
    'queued incoming cancel leaves active and skips to the next valid item',
    () async {
      final root = await Directory.systemTemp.createTemp('whisper-incoming-');
      addTearDown(() => root.delete(recursive: true));
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final sent = <WhisperFrameV3>[];
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
      );
      final checksum = bytesChecksum(const <int>[1], algorithm: 'sha256');
      for (final id in <String>[_firstId, _secondId, _thirdId]) {
        await engine.handleFrame(
          _binding,
          _offerFrame(_incomingMessage(id, size: 1, checksum: checksum)),
          requireCurrent: () {},
        );
      }

      await engine.cancelTransfer(_secondId);
      expect(_readyFrames(sent, _thirdId), isEmpty);
      await engine.cancelTransfer(_firstId);

      expect(_readyFrames(sent, _secondId), isEmpty);
      expect(_readyFrames(sent, _thirdId), hasLength(1));
      expect(
        sent.where((frame) => frame.type == WhisperFrameType.fileCancel),
        hasLength(2),
      );
      expect(
        (await database.fetchFileTransfer(_firstId))?.state,
        FileTransferState.paused,
      );
      expect(
        (await database.fetchFileTransfer(_secondId))?.state,
        FileTransferState.paused,
      );
    },
  );

  for (final corrupt in <bool>[false, true]) {
    test(
      'incoming ${corrupt ? 'integrity failure' : 'completion'} advances queue',
      () async {
        final root = await Directory.systemTemp.createTemp('whisper-incoming-');
        addTearDown(() => root.delete(recursive: true));
        final database = LocalDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        final sent = <WhisperFrameV3>[];
        final engine = _engine(
          database,
          sent,
          downloadDirectory: () async => root,
        );
        final checksum = bytesChecksum(const <int>[1], algorithm: 'sha256');
        for (final id in <String>[_firstId, _secondId]) {
          await engine.handleFrame(
            _binding,
            _offerFrame(_incomingMessage(id, size: 1, checksum: checksum)),
            requireCurrent: () {},
          );
        }

        await engine.handleFrame(
          _binding,
          WhisperFrameV3(
            type: WhisperFrameType.fileData,
            transferId: _firstId,
            offset: 0,
            sequence: 0,
            payload: Uint8List.fromList(<int>[corrupt ? 2 : 1]),
          ),
          requireCurrent: () {},
        );

        expect(_readyFrames(sent, _secondId), hasLength(1));
        expect(
          (await database.fetchFileTransfer(_firstId))?.state,
          corrupt ? FileTransferState.failed : FileTransferState.completed,
        );
      },
    );
  }

  test('incoming publish failure releases once and advances queue', () async {
    final root = await Directory.systemTemp.createTemp('whisper-incoming-');
    addTearDown(() => root.delete(recursive: true));
    final database = _FailingPublishDatabase();
    addTearDown(database.close);
    final sent = <WhisperFrameV3>[];
    final engine = _engine(database, sent, downloadDirectory: () async => root);
    final checksum = bytesChecksum(const <int>[1], algorithm: 'sha256');
    for (final id in <String>[_firstId, _secondId]) {
      await engine.handleFrame(
        _binding,
        _offerFrame(_incomingMessage(id, size: 1, checksum: checksum)),
        requireCurrent: () {},
      );
    }

    await engine.handleFrame(
      _binding,
      WhisperFrameV3(
        type: WhisperFrameType.fileData,
        transferId: _firstId,
        offset: 0,
        sequence: 0,
        payload: Uint8List.fromList(const <int>[1]),
      ),
      requireCurrent: () {},
    );

    expect(_readyFrames(sent, _secondId), hasLength(1));
    expect(
      (await database.fetchFileTransfer(_firstId))?.state,
      FileTransferState.failed,
    );
  });

  test(
    'disconnect pauses without progression and resume starts at committed',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      await _persistOutgoing(database, _firstId, size: 4);
      await _persistOutgoing(database, _secondId, size: 1);
      final scheduler = _FakeTimerScheduler();
      final watchdog = TransferAckWatchdog(timerFactory: scheduler.createTimer);
      final sent = <WhisperFrameV3>[];
      final engine = _engine(
        database,
        sent,
        ackWatchdog: watchdog,
        sourceFactory: (_, expectedSize) => _SizedSource(expectedSize),
      );
      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(FileTransferV3Action.ready, _firstId, size: 4, offset: 0),
        ),
        requireCurrent: () {},
      );
      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(FileTransferV3Action.ready, _secondId, size: 1, offset: 0),
        ),
        requireCurrent: () {},
      );
      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(FileTransferV3Action.ack, _firstId, size: 4, offset: 2),
        ),
        requireCurrent: () {},
      );
      final dataBeforeDisconnect = sent
          .where((frame) => frame.type == WhisperFrameType.fileData)
          .length;

      await engine.handlePeerDisconnected('peer-a');

      expect(watchdog.currentWindow(_firstId), isNull);
      expect(
        (await database.fetchFileTransfer(_firstId))?.state,
        FileTransferState.waitingReconnect,
      );
      expect(
        (await database.fetchFileTransfer(_secondId))?.state,
        FileTransferState.waitingReconnect,
      );
      expect(
        sent.where((frame) => frame.type == WhisperFrameType.fileData).length,
        dataBeforeDisconnect,
      );

      sent.clear();
      await engine.resumeRecoverableOutgoing();
      expect(
        sent.where((frame) => frame.type == WhisperFrameType.fileOffer),
        hasLength(2),
      );
      const resume = FileTransferV3Control(
        action: FileTransferV3Action.ready,
        transferId: _firstId,
        durableOffset: 2,
        size: 4,
        failureReason: FileTransferFailureReason.none,
        resumeProofSha256:
            '96a296d224f285c67bee93c30f8a309157f0daa35dc5b87e410b78630a09cfc7',
        resumeProofLength: 2,
      );
      await engine.handleFrame(
        _binding,
        _controlFrame(resume),
        requireCurrent: () {},
      );

      expect(_dataFrames(sent, _firstId).first.offset, 2);
    },
  );

  test(
    'restart and reconnect expose interrupted progress for manual resume',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'whisper-incoming-reconnect-',
      );
      addTearDown(() => root.delete(recursive: true));
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final bytes = Uint8List.fromList(const <int>[1, 2, 3, 4]);
      final checksum = bytesChecksum(bytes, algorithm: 'sha256');
      final message = await database.insertMessageReturning(
        _incomingMessage(_firstId, size: bytes.length, checksum: checksum),
      );
      final temp = File(await safeTransferTempPath(root, _firstId));
      await temp.parent.create(recursive: true);
      await temp.writeAsBytes(bytes.sublist(0, 2));
      await database.upsertFileTransfer(
        _incomingTransfer(
          _firstId,
          size: bytes.length,
          messageRowId: message.id,
          tempPath: temp.path,
          committedBytes: 2,
          checksum: checksum,
        ).copyWith(state: FileTransferState.transferring),
      );
      final sent = <WhisperFrameV3>[];
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
      );

      await engine.reconcileInterruptedTransfersOnStartup();

      expect(sent, isEmpty);
      expect(
        (await database.fetchFileTransfer(_firstId))?.state,
        FileTransferState.waitingReconnect,
      );

      await engine.markRecoverableTransfersPausedForPeer('peer-a');

      expect(sent, isEmpty);
      expect(
        (await database.fetchFileTransfer(_firstId))?.state,
        FileTransferState.paused,
      );

      await engine.retryTransfer(_firstId);

      expect(sent, isEmpty);
      expect(
        (await database.fetchFileTransfer(_firstId))?.state,
        FileTransferState.paused,
      );
    },
  );

  test(
    're-sent offer refreshes legacy rhythm metadata to current constants',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final checksum = 'ab' * 32;
      // 升级前(16MiB 发送窗口)创建并中断的传输:DB 里的 offer content
      // 仍是旧节奏常量;续传重发时必须用当前常量重建节奏字段,
      // 身份字段(校验和)保持不变,否则对端 parseOffer 永久拒绝。
      final legacyContent = jsonEncode(<String, Object>{
        'protocolVersion': fileTransferV3ProtocolVersion,
        'checksumAlgorithm': fileTransferV3ChecksumAlgorithm,
        'checksumValue': checksum,
        'chunkSize': fileTransferV3FramePayloadSize,
        'windowSize': 16 * 1024 * 1024,
      });
      final message = await database.insertMessageReturning(
        _outgoingMessage(
          _firstId,
          size: 4,
        ).copyWith(content: Value<String?>(legacyContent)),
      );
      await database.upsertFileTransfer(
        _outgoingTransfer(
          _firstId,
          size: 4,
          messageRowId: message.id,
        ).copyWith(state: FileTransferState.waitingReconnect),
      );
      final sent = <WhisperFrameV3>[];
      final engine = _engine(
        database,
        sent,
        sourceFactory: (_, expectedSize) => _SizedSource(expectedSize),
      );

      await engine.resumeRecoverableOutgoing();

      final offer = sent.singleWhere(
        (frame) => frame.type == WhisperFrameType.fileOffer,
      );
      final wire = decodeWireMessage(
        jsonDecode(utf8.decode(offer.payload)) as Map<String, dynamic>,
      );
      final refreshed = jsonDecode(wire.content ?? '') as Map<String, dynamic>;
      expect(refreshed['checksumValue'], checksum);
      expect(refreshed['chunkSize'], fileTransferV3FramePayloadSize);
      expect(refreshed['windowSize'], fileTransferV3WindowSize);
      final metadata = FileTransferV3Metadata.parseOffer(
        wire.content,
        size: wire.size,
      );
      expect(metadata.checksumValue, checksum);
    },
  );

  test(
    'retry offer without parsable metadata keeps the stored content',
    () async {
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      // 内容不可解析(测试夹具的 '{}')时按原样重发,不得丢帧或抛错。
      await _persistOutgoing(database, _firstId, size: 4);
      await database.updateFileTransfer(
        _firstId,
        state: const Value(FileTransferState.waitingReconnect),
      );
      final sent = <WhisperFrameV3>[];
      final engine = _engine(
        database,
        sent,
        sourceFactory: (_, expectedSize) => _SizedSource(expectedSize),
      );

      await engine.resumeRecoverableOutgoing();

      final offer = sent.singleWhere(
        (frame) => frame.type == WhisperFrameType.fileOffer,
      );
      final wire = decodeWireMessage(
        jsonDecode(utf8.decode(offer.payload)) as Map<String, dynamic>,
      );
      expect(wire.content, '{}');
    },
  );

  test('engine close cancels every outstanding ACK timer', () async {
    final database = LocalDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await _persistOutgoing(database, _firstId, size: 1);
    final scheduler = _FakeTimerScheduler();
    final watchdog = TransferAckWatchdog(timerFactory: scheduler.createTimer);
    final engine = _engine(
      database,
      <WhisperFrameV3>[],
      ackWatchdog: watchdog,
      sourceFactory: (_, expectedSize) => _SizedSource(expectedSize),
    );
    await engine.handleFrame(
      _binding,
      _controlFrame(
        _control(FileTransferV3Action.ready, _firstId, size: 1, offset: 0),
      ),
      requireCurrent: () {},
    );
    expect(scheduler.activeTimerCount, 1);

    await engine.closeAll(persistRecoverable: false);

    expect(watchdog.currentWindow(_firstId), isNull);
    expect(scheduler.activeTimerCount, 0);
  });

  test('outgoing successor loop skips every stale queue shape', () async {
    final database = _StaleQueueDatabase();
    addTearDown(database.close);
    final ids = <String>[
      _firstId,
      _secondId,
      _thirdId,
      _fourthId,
      _fifthId,
      _sixthId,
    ];
    for (final id in ids) {
      await _persistOutgoing(database, id, size: 1);
    }
    final sent = <WhisperFrameV3>[];
    final engine = _engine(
      database,
      sent,
      sourceFactory: (_, expectedSize) => _SizedSource(expectedSize),
    );
    for (final id in ids) {
      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(FileTransferV3Action.ready, id, size: 1, offset: 0),
        ),
        requireCurrent: () {},
      );
    }
    await database.updateFileTransfer(
      _thirdId,
      state: const Value(FileTransferState.canceled),
    );
    database.activateStaleQueue();

    await engine.handleFrame(
      _binding,
      _controlFrame(
        _control(FileTransferV3Action.complete, _firstId, size: 1, offset: 1),
      ),
      requireCurrent: () {},
    );

    expect(_dataFrames(sent, _secondId), isEmpty);
    expect(_dataFrames(sent, _thirdId), isEmpty);
    expect(_dataFrames(sent, _fourthId), isEmpty);
    expect(_dataFrames(sent, _fifthId), isEmpty);
    expect(_dataFrames(sent, _sixthId), hasLength(1));
  });

  test(
    'incoming successor loop persistently skips every stale queue shape',
    () async {
      final root = await Directory.systemTemp.createTemp('whisper-incoming-');
      addTearDown(() => root.delete(recursive: true));
      final database = _IncomingStaleQueueDatabase();
      addTearDown(database.close);
      final sent = <WhisperFrameV3>[];
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
      );
      final checksum = bytesChecksum(const <int>[1], algorithm: 'sha256');
      for (final id in <String>[
        _firstId,
        _secondId,
        _thirdId,
        _fourthId,
        _fifthId,
        _sixthId,
      ]) {
        await engine.handleFrame(
          _binding,
          _offerFrame(_incomingMessage(id, size: 1, checksum: checksum)),
          requireCurrent: () {},
        );
      }
      await database.updateFileTransfer(
        _thirdId,
        state: const Value(FileTransferState.canceled),
      );
      database.activateStaleQueue();

      await engine.handleFrame(
        _binding,
        _controlFrame(
          _control(FileTransferV3Action.cancel, _firstId, size: 1, offset: 0),
        ),
        requireCurrent: () {},
      );

      expect(_readyFrames(sent, _secondId), isEmpty);
      expect(_readyFrames(sent, _thirdId), isEmpty);
      expect(_readyFrames(sent, _fourthId), isEmpty);
      expect(_readyFrames(sent, _fifthId), isEmpty);
      expect(_readyFrames(sent, _sixthId), hasLength(1));
      expect(
        (await database.fetchFileTransfer(_thirdId))?.state,
        FileTransferState.canceled,
      );
      expect(
        (await database.fetchFileTransfer(_fourthId))?.state,
        FileTransferState.failed,
      );
      expect(
        (await database.fetchFileTransfer(_fourthId))?.lastError,
        'stale_queue',
      );
      expect(
        (await database.fetchFileTransfer(_fifthId))?.state,
        FileTransferState.failed,
      );
      expect(
        (await database.fetchFileTransfer(_fifthId))?.lastError,
        'stale_queue',
      );
      expect(database.claimFailureCount, 1);
    },
  );
}

FileTransferEngine _engine(
  LocalDatabase database,
  List<WhisperFrameV3> sent, {
  TransferAckWatchdog? ackWatchdog,
  FileTransferSource Function(String sourcePath, int expectedSize)?
  sourceFactory,
  Future<Directory> Function()? downloadDirectory,
  FutureOr<bool> Function(TransferConnectionBinding binding)?
  markPeerUnresponsive,
  FutureOr<bool> Function(
    TransferConnectionBinding binding,
    WhisperFrameV3 frame,
  )?
  sendBytesToConnection,
  TransferConnectionBinding? Function(String peerId)? currentConnectionBinding,
  Set<String> Function()? connectedPeerIds,
  PeerProfile? Function(String peerId)? remoteProfileFor,
}) {
  return FileTransferEngine(
    currentConnectionBinding:
        currentConnectionBinding ??
        (peerId) => peerId == _binding.peerId ? _binding : null,
    authenticatedIdentityHashForConnection: (_) => null,
    sendBytesToConnection: (connection, bytes) {
      if (sendBytesToConnection == null) {
        expect(connection, _binding);
      }
      final frame = WhisperFrameV3.decode(bytes as Uint8List);
      sent.add(frame);
      return sendBytesToConnection?.call(connection, frame) ?? true;
    },
    markPeerUnresponsive: markPeerUnresponsive ?? (_) => true,
    ackWatchdog: ackWatchdog,
    emitTransferUpdated: (_) {},
    notify: (_) {},
    remoteProfileFor: remoteProfileFor ?? (_) => _capablePeer(),
    isConnectedTo: (_) => true,
    connectedPeerIds: connectedPeerIds ?? () => const <String>{'peer-a'},
    defaultPeerId: () => '',
    hasLegacySinkFor: (_) => false,
    localPeerIdFor: (_) => 'local',
    buildMessage:
        (
          type,
          content,
          msg,
          fileName,
          size,
          clipboard, {
          md5 = '',
          path = '',
          uid,
          fileTimestamp,
          receiverOverride,
        }) => throw UnimplementedError(),
    dispatchOutgoingMessage: (_) {},
    ackMessage: (_) {},
    wireMessageReplayGuard: WireMessageReplayGuard(),
    transferSourceFactory: sourceFactory,
    downloadDirectory: downloadDirectory,
    database: () => database,
  );
}

Future<void> _persistOutgoing(
  LocalDatabase database,
  String id, {
  required int size,
}) async {
  final message = await database.insertMessageReturning(
    _outgoingMessage(id, size: size),
  );
  await database.upsertFileTransfer(
    _outgoingTransfer(id, size: size, messageRowId: message.id),
  );
}

MessageData _outgoingMessage(String id, {required int size}) => MessageData(
  id: 0,
  sender: 'local',
  receiver: 'peer-a',
  name: '$id.bin',
  clipboard: false,
  size: size,
  type: MessageEnum.File,
  content: '{}',
  message: '',
  timestamp: 1,
  uuid: id,
  acked: false,
  path: '/virtual/$id',
  md5: '',
);

MessageData _incomingMessage(
  String id, {
  required int size,
  required String checksum,
  String peerId = 'peer-a',
}) => MessageData(
  id: 0,
  sender: peerId,
  receiver: 'local',
  name: '$id.bin',
  clipboard: false,
  size: size,
  type: MessageEnum.File,
  content: jsonEncode(FileTransferV3Metadata(checksumValue: checksum).toJson()),
  message: '',
  timestamp: 1,
  uuid: id,
  acked: false,
  path: '',
  md5: '',
);

FileTransferData _outgoingTransfer(
  String id, {
  required int size,
  required int messageRowId,
}) => FileTransferData(
  transferId: id,
  messageUuid: id,
  messageRowId: messageRowId,
  peerUid: 'peer-a',
  direction: FileTransferDirection.outgoing,
  state: FileTransferState.negotiating,
  finalPath: '/virtual/$id',
  tempPath: '',
  size: size,
  checksumAlgorithm: 'sha256',
  checksumValue: '0' * 64,
  chunkSize: fileTransferV3FramePayloadSize,
  committedBytes: 0,
  resumeProofResetCount: 0,
  lastError: '',
  createdAt: int.parse(id.substring(0, 2), radix: 16) + 1,
  updatedAt: 1,
);

FileTransferData _incomingTransfer(
  String id, {
  required int size,
  required int messageRowId,
  required String tempPath,
  required int committedBytes,
  required String checksum,
  String peerId = 'peer-a',
}) => FileTransferData(
  transferId: id,
  messageUuid: id,
  messageRowId: messageRowId,
  peerUid: peerId,
  direction: FileTransferDirection.incoming,
  state: FileTransferState.negotiating,
  finalPath: '',
  tempPath: tempPath,
  size: size,
  checksumAlgorithm: 'sha256',
  checksumValue: checksum,
  chunkSize: fileTransferV3FramePayloadSize,
  committedBytes: committedBytes,
  resumeProofResetCount: 0,
  lastError: '',
  createdAt: 1,
  updatedAt: 1,
);

FileTransferV3Control _control(
  FileTransferV3Action action,
  String id, {
  required int size,
  required int offset,
}) => FileTransferV3Control(
  action: action,
  transferId: id,
  durableOffset: offset,
  size: size,
  failureReason: action == FileTransferV3Action.error
      ? FileTransferFailureReason.remoteFailure
      : FileTransferFailureReason.none,
);

WhisperFrameV3 _controlFrame(FileTransferV3Control control) => WhisperFrameV3(
  type: switch (control.action) {
    FileTransferV3Action.ready => WhisperFrameType.fileReady,
    FileTransferV3Action.ack => WhisperFrameType.fileAck,
    FileTransferV3Action.verify => WhisperFrameType.fileAck,
    FileTransferV3Action.complete => WhisperFrameType.fileComplete,
    FileTransferV3Action.cancel => WhisperFrameType.fileCancel,
    FileTransferV3Action.error => WhisperFrameType.fileError,
  },
  transferId: control.transferId,
  offset: control.durableOffset,
  sequence: 0,
  payload: Uint8List.fromList(utf8.encode(jsonEncode(control.toJson()))),
);

WhisperFrameV3 _offerFrame(MessageData message) => WhisperFrameV3(
  type: WhisperFrameType.fileOffer,
  transferId: message.uuid,
  offset: 0,
  sequence: 0,
  payload: Uint8List.fromList(utf8.encode(encodeWireMessage(message))),
);

Iterable<WhisperFrameV3> _dataFrames(
  Iterable<WhisperFrameV3> frames,
  String transferId,
) => frames.where(
  (frame) =>
      frame.type == WhisperFrameType.fileData && frame.transferId == transferId,
);

Iterable<WhisperFrameV3> _readyFrames(
  Iterable<WhisperFrameV3> frames,
  String transferId,
) => frames.where(
  (frame) =>
      frame.type == WhisperFrameType.fileReady &&
      frame.transferId == transferId,
);

PeerProfile _capablePeer([String peerId = 'peer-a']) => PeerProfile(
  device: DeviceData(
    id: 0,
    uid: peerId,
    name: peerId,
    host: '192.168.1.2',
    port: 10002,
    password: '',
    platform: 'test',
    isServer: false,
    online: true,
    clipboard: false,
    auth: true,
    lastTime: 1,
    around: true,
  ),
  trustedPeerIds: const <String>[],
  autoApproveNewDevices: false,
  autoConnectEnabled: true,
  capabilities: const PeerCapabilities(fileTransferV3: true),
);

final class _SizedSource implements FileTransferSource {
  const _SizedSource(this.size);

  final int size;

  @override
  Future<bool> exists() async => true;

  @override
  Future<int> length() async => size;

  @override
  Future<Uint8List> readRange(int offset, int length) async =>
      Uint8List(length);
}

final class _GatedFailingSource implements FileTransferSource {
  const _GatedFailingSource(
    this.size, {
    required this.readStarted,
    required this.releaseRead,
  });

  final int size;
  final Completer<void> readStarted;
  final Completer<void> releaseRead;

  @override
  Future<bool> exists() async => true;

  @override
  Future<int> length() async => size;

  @override
  Future<Uint8List> readRange(int offset, int length) async {
    if (!readStarted.isCompleted) {
      readStarted.complete();
    }
    await releaseRead.future;
    throw const FileSystemException('injected source read failure');
  }
}

final class _FailingPublishDatabase extends LocalDatabase {
  _FailingPublishDatabase() : super.forTesting(NativeDatabase.memory());

  @override
  Future<FileTransferData> completeIncomingFileTransfer({
    required String transferId,
    required String finalPath,
    required int size,
  }) {
    throw StateError('injected publish persistence failure');
  }
}

final class _StaleQueueDatabase extends LocalDatabase {
  _StaleQueueDatabase() : super.forTesting(NativeDatabase.memory());

  bool _staleQueueActive = false;

  void activateStaleQueue() => _staleQueueActive = true;

  @override
  Future<FileTransferData?> fetchFileTransfer(String transferId) {
    if (_staleQueueActive && transferId == _secondId) {
      return Future<FileTransferData?>.value();
    }
    return super.fetchFileTransfer(transferId);
  }

  @override
  Future<MessageData?> fetchAssociatedFileTransferMessage(
    FileTransferData transfer,
  ) {
    if (_staleQueueActive && transfer.transferId == _fourthId) {
      return Future<MessageData?>.value();
    }
    return super.fetchAssociatedFileTransferMessage(transfer);
  }

  @override
  Future<int> updateFileTransfer(
    String transferId, {
    Value<FileTransferState> state = const Value.absent(),
    Value<int> committedBytes = const Value.absent(),
    Value<String> lastError = const Value.absent(),
    Value<String> finalPath = const Value.absent(),
    Value<String> tempPath = const Value.absent(),
    Value<String> checksumValue = const Value.absent(),
    Value<int> updatedAt = const Value.absent(),
  }) {
    if (_staleQueueActive &&
        transferId == _fifthId &&
        state.present &&
        state.value == FileTransferState.transferring) {
      return Future<int>.value(0);
    }
    return super.updateFileTransfer(
      transferId,
      state: state,
      committedBytes: committedBytes,
      lastError: lastError,
      finalPath: finalPath,
      tempPath: tempPath,
      checksumValue: checksumValue,
      updatedAt: updatedAt,
    );
  }
}

final class _IncomingStaleQueueDatabase extends LocalDatabase {
  _IncomingStaleQueueDatabase() : super.forTesting(NativeDatabase.memory());

  bool _staleQueueActive = false;
  int claimFailureCount = 0;

  void activateStaleQueue() => _staleQueueActive = true;

  @override
  Future<FileTransferData?> fetchFileTransfer(String transferId) {
    if (_staleQueueActive && transferId == _secondId) {
      return Future<FileTransferData?>.value();
    }
    return super.fetchFileTransfer(transferId);
  }

  @override
  Future<List<FileTransferData>> fetchRecoverableFileTransfersForPeer(
    String peerUid, {
    FileTransferDirection? direction,
  }) async {
    final items = await super.fetchRecoverableFileTransfersForPeer(
      peerUid,
      direction: direction,
    );
    if (!_staleQueueActive) {
      return items;
    }
    return items
        .where((item) => item.transferId != _secondId)
        .toList(growable: false);
  }

  @override
  Future<MessageData?> fetchAssociatedFileTransferMessage(
    FileTransferData transfer,
  ) {
    if (_staleQueueActive && transfer.transferId == _fourthId) {
      return Future<MessageData?>.value();
    }
    return super.fetchAssociatedFileTransferMessage(transfer);
  }

  @override
  Future<int> updateFileTransfer(
    String transferId, {
    Value<FileTransferState> state = const Value.absent(),
    Value<int> committedBytes = const Value.absent(),
    Value<String> lastError = const Value.absent(),
    Value<String> finalPath = const Value.absent(),
    Value<String> tempPath = const Value.absent(),
    Value<String> checksumValue = const Value.absent(),
    Value<int> updatedAt = const Value.absent(),
  }) {
    if (_staleQueueActive &&
        transferId == _fifthId &&
        state.present &&
        state.value == FileTransferState.negotiating) {
      claimFailureCount += 1;
      return Future<int>.value(0);
    }
    return super.updateFileTransfer(
      transferId,
      state: state,
      committedBytes: committedBytes,
      lastError: lastError,
      finalPath: finalPath,
      tempPath: tempPath,
      checksumValue: checksumValue,
      updatedAt: updatedAt,
    );
  }
}

final class _FakeTimerScheduler {
  final List<_FakeTimer> _timers = <_FakeTimer>[];

  int get activeTimerCount => _timers.where((timer) => timer.isActive).length;

  Timer createTimer(Duration delay, void Function() callback) {
    final timer = _FakeTimer(callback);
    _timers.add(timer);
    return timer;
  }

  Future<void> fireNext() async {
    final timer = _timers.firstWhere((candidate) => candidate.isActive);
    timer.fire();
    await pumpEventQueue();
  }
}

final class _FakeTimer implements Timer {
  _FakeTimer(this.callback);

  final void Function() callback;
  bool active = true;

  @override
  bool get isActive => active;

  @override
  int get tick => active ? 0 : 1;

  @override
  void cancel() => active = false;

  void fire() {
    if (!active) {
      return;
    }
    active = false;
    callback();
  }
}
