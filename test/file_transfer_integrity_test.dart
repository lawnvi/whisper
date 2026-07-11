import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show QueryExecutor, Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/helper/file.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/file_transfer_engine.dart';
import 'package:whisper/socket/file_path_policy.dart';
import 'package:whisper/socket/file_transfer_source.dart';
import 'package:whisper/socket/file_transfer_v3.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';
import 'package:whisper/socket/wire_message_codec.dart';
import 'package:whisper/socket/wire_message_replay.dart';

const _emptySha256 =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

TransferConnectionBinding _connection(String peerId) =>
    TransferConnectionBinding(peerId: peerId, generation: 1);

void main() {
  group('FileTransferV3Metadata', () {
    Map<String, Object> validJson() => <String, Object>{
          'protocolVersion': fileTransferV3ProtocolVersion,
          'checksumAlgorithm': fileTransferV3ChecksumAlgorithm,
          'checksumValue': _emptySha256,
          'chunkSize': fileTransferV3FramePayloadSize,
          'windowSize': fileTransferV3WindowSize,
        };

    test('accepts fixed metadata and inclusive size bounds', () {
      for (final size in <int>[0, fileTransferV3MaxFileSize]) {
        final metadata = FileTransferV3Metadata.parseOffer(
          jsonEncode(validJson()),
          size: size,
        );

        expect(metadata.checksumAlgorithm, 'sha256');
        expect(metadata.checksumValue, _emptySha256);
        expect(metadata.chunkSize, fileTransferV3FramePayloadSize);
        expect(metadata.windowSize, fileTransferV3WindowSize);
      }
    });

    test('accepts bounded rhythm values from other protocol generations', () {
      // 节奏字段(chunkSize/windowSize)做有界区间校验,不与本端当前常量
      // 精确相等绑定:升级把 16MiB 窗口降到 4MiB 后,DB 里旧 offer 原样
      // 重发仍必须可续传,接收侧背压是优雅 pause,可容忍更大窗口。
      final cases = <({int chunkSize, int windowSize})>[
        // 升级前的 16MiB 发送窗口。
        (
          chunkSize: fileTransferV3FramePayloadSize,
          windowSize: 16 * 1024 * 1024,
        ),
        // 半帧 chunk 与当前窗口。
        (
          chunkSize: fileTransferV3FramePayloadSize ~/ 2,
          windowSize: fileTransferV3WindowSize,
        ),
        // 下界:窗口恰好一帧。
        (
          chunkSize: fileTransferV3FramePayloadSize,
          windowSize: fileTransferV3FramePayloadSize,
        ),
        // 上界:32MiB 窗口。
        (
          chunkSize: fileTransferV3FramePayloadSize,
          windowSize: fileTransferV3MaxOfferWindowSize,
        ),
      ];

      for (final item in cases) {
        final metadata = FileTransferV3Metadata.parseOffer(
          jsonEncode(<String, Object>{
            ...validJson(),
            'chunkSize': item.chunkSize,
            'windowSize': item.windowSize,
          }),
          size: 1,
        );
        expect(metadata.checksumValue, _emptySha256);
        expect(metadata.chunkSize, item.chunkSize);
        expect(metadata.windowSize, item.windowSize);
      }
    });

    test('rejects invalid size, digest, algorithm, chunk, and window', () {
      final cases = <({int size, Map<String, Object> json, String reason})>[
        (size: -1, json: validJson(), reason: 'invalid_size'),
        (
          size: fileTransferV3MaxFileSize + 1,
          json: validJson(),
          reason: 'invalid_size',
        ),
        (
          size: 1,
          json: <String, Object>{
            ...validJson(),
            'checksumAlgorithm': 'none',
          },
          reason: 'invalid_metadata',
        ),
        (
          size: 1,
          json: <String, Object>{
            ...validJson(),
            'checksumValue': 'abc123',
          },
          reason: 'invalid_metadata',
        ),
        (
          size: 1,
          json: <String, Object>{
            ...validJson(),
            'checksumValue': _emptySha256.toUpperCase(),
          },
          reason: 'invalid_metadata',
        ),
        // chunk 必须为正且不超过窗口。
        (
          size: 1,
          json: <String, Object>{
            ...validJson(),
            'chunkSize': 0,
          },
          reason: 'invalid_metadata',
        ),
        (
          size: 1,
          json: <String, Object>{
            ...validJson(),
            'chunkSize': fileTransferV3WindowSize + 1,
          },
          reason: 'invalid_metadata',
        ),
        (
          size: 1,
          json: <String, Object>{
            ...validJson(),
            'chunkSize': '$fileTransferV3FramePayloadSize',
          },
          reason: 'invalid_metadata',
        ),
        // 窗口必须落在 [一帧, 32MiB] 且为帧长整数倍。
        (
          size: 1,
          json: <String, Object>{
            ...validJson(),
            'windowSize': fileTransferV3FramePayloadSize - 1,
          },
          reason: 'invalid_metadata',
        ),
        (
          size: 1,
          json: <String, Object>{
            ...validJson(),
            'windowSize':
                fileTransferV3MaxOfferWindowSize + fileTransferV3FramePayloadSize,
          },
          reason: 'invalid_metadata',
        ),
        (
          size: 1,
          json: <String, Object>{
            ...validJson(),
            'windowSize': fileTransferV3WindowSize + 1,
          },
          reason: 'invalid_metadata',
        ),
        (
          size: 1,
          json: <String, Object>{
            ...validJson(),
            'windowSize': '$fileTransferV3WindowSize',
          },
          reason: 'invalid_metadata',
        ),
      ];

      for (final item in cases) {
        expect(
          () => FileTransferV3Metadata.parseOffer(
            jsonEncode(item.json),
            size: item.size,
          ),
          throwsA(
            isA<FileTransferV3MetadataException>().having(
              (error) => error.reason,
              'reason',
              item.reason,
            ),
          ),
        );
      }
    });
  });

  group('resume proof behavior', () {
    const transferId = '01234567-89ab-4cde-8fab-0123456789ab';

    test('sender accepts a matching proof and rejects a mismatched prefix',
        () async {
      final directory = await Directory.systemTemp.createTemp('whisper-proof-');
      addTearDown(() => directory.delete(recursive: true));
      final sourceFile = File(p.join(directory.path, 'source.bin'));
      final bytes = Uint8List.fromList(List<int>.generate(8, (i) => i));
      await sourceFile.writeAsBytes(bytes);
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final persistedMessage = await database.insertMessageReturning(_message(
        transferId: transferId,
        sender: 'local',
        receiver: 'peer-a',
        path: sourceFile.path,
        size: bytes.length,
      ));
      await database.upsertFileTransfer(_transfer(
        transferId: transferId,
        peerUid: 'peer-a',
        direction: FileTransferDirection.outgoing,
        state: FileTransferState.negotiating,
        path: sourceFile.path,
        size: bytes.length,
        messageRowId: persistedMessage.id,
      ));
      final sent = <WhisperFrameV3>[];
      final engine = _engine(database, sent);

      final matching = FileTransferV3Control(
        action: FileTransferV3Action.ready,
        transferId: transferId,
        durableOffset: 4,
        size: bytes.length,
        failureReason: FileTransferFailureReason.none,
        resumeProofSha256: bytesChecksum(
          bytes.sublist(0, 4),
          algorithm: 'sha256',
        ),
        resumeProofLength: 4,
      );
      await engine.handleFrame(
        _connection('peer-a'),
        _controlFrame(matching),
        requireCurrent: () {},
      );
      expect(sent.where((frame) => frame.type == WhisperFrameType.fileData),
          isNotEmpty);
      expect(
        sent
            .firstWhere((frame) => frame.type == WhisperFrameType.fileData)
            .offset,
        4,
      );

      sent.clear();
      await database.updateFileTransfer(
        transferId,
        state: const Value(FileTransferState.negotiating),
        committedBytes: const Value(0),
      );
      final mismatched = FileTransferV3Control(
        action: FileTransferV3Action.ready,
        transferId: transferId,
        durableOffset: 4,
        size: bytes.length,
        failureReason: FileTransferFailureReason.none,
        resumeProofSha256: '0' * 64,
        resumeProofLength: 4,
      );
      await engine.handleFrame(
        _connection('peer-a'),
        _controlFrame(mismatched),
        requireCurrent: () {},
      );
      final error = sent.singleWhere(
        (frame) => frame.type == WhisperFrameType.fileError,
      );
      final errorControl = FileTransferV3Control.fromJson(
        jsonDecode(utf8.decode(error.payload)) as Map<String, dynamic>,
      );
      expect(errorControl.errorCode, 'resume_proof_mismatch');
      expect(
        sent.where((frame) => frame.type == WhisperFrameType.fileData),
        isEmpty,
      );
    });

    test('receiver resets a mismatched prefix once and then fails', () async {
      final directory = await Directory.systemTemp.createTemp('whisper-reset-');
      addTearDown(() => directory.delete(recursive: true));
      final temp = File(await safeTransferTempPath(directory, transferId));
      await temp.parent.create(recursive: true);
      await temp.writeAsBytes(const <int>[1, 2, 3, 4]);
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final persistedMessage = await database.insertMessageReturning(_message(
        transferId: transferId,
        sender: 'peer-a',
        receiver: 'local',
        path: '',
        size: 8,
      ));
      await database.upsertFileTransfer(_transfer(
        transferId: transferId,
        peerUid: 'peer-a',
        direction: FileTransferDirection.incoming,
        state: FileTransferState.negotiating,
        path: '',
        tempPath: temp.path,
        size: 8,
        committedBytes: 4,
        messageRowId: persistedMessage.id,
      ));
      final sent = <WhisperFrameV3>[];
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => directory,
      );
      const mismatch = FileTransferV3Control(
        action: FileTransferV3Action.error,
        transferId: transferId,
        durableOffset: 4,
        size: 8,
        failureReason: FileTransferFailureReason.resumeProofMismatch,
      );

      await engine.handleFrame(
        _connection('peer-a'),
        _controlFrame(mismatch),
        requireCurrent: () {},
      );
      expect(await temp.length(), 0);
      expect(
        (await database.fetchFileTransfer(transferId))?.committedBytes,
        0,
      );
      expect(
        (await database.fetchFileTransfer(transferId))?.resumeProofResetCount,
        1,
      );
      final ready = sent.singleWhere(
        (frame) => frame.type == WhisperFrameType.fileReady,
      );
      final readyControl = FileTransferV3Control.fromJson(
        jsonDecode(utf8.decode(ready.payload)) as Map<String, dynamic>,
      );
      expect(readyControl.durableOffset, 0);
      expect(readyControl.resumeProofLength, 0);

      await temp.writeAsBytes(const <int>[5, 6, 7, 8]);
      await database.updateFileTransfer(
        transferId,
        state: const Value(FileTransferState.negotiating),
        committedBytes: const Value(4),
      );
      sent.clear();
      final recreatedEngine = _engine(
        database,
        sent,
        downloadDirectory: () async => directory,
      );
      await recreatedEngine.handleFrame(
        _connection('peer-a'),
        _controlFrame(mismatch),
        requireCurrent: () {},
      );
      expect(
        (await database.fetchFileTransfer(transferId))?.state,
        FileTransferState.failed,
      );
      expect(
        sent.where((frame) => frame.type == WhisperFrameType.fileReady),
        isEmpty,
      );
      expect(await temp.length(), 4);
    });

    test('a recreated engine completes a persisted pending proof reset',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('whisper-reset-recovery-');
      addTearDown(() => directory.delete(recursive: true));
      final temp = File(await safeTransferTempPath(directory, transferId));
      await temp.parent.create(recursive: true);
      await temp.writeAsBytes(const <int>[1, 2, 3, 4]);
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final offer = _message(
        transferId: transferId,
        sender: 'peer-a',
        receiver: 'local',
        path: '',
        size: 8,
      );
      final message = await database.insertMessageReturning(offer);
      await database.upsertFileTransfer(_transfer(
        transferId: transferId,
        peerUid: 'peer-a',
        direction: FileTransferDirection.incoming,
        state: FileTransferState.negotiating,
        path: '',
        tempPath: temp.path,
        size: 8,
        committedBytes: 4,
        messageRowId: message.id,
        resumeProofResetCount: pendingResumeProofResetMarker,
      ));
      final sent = <WhisperFrameV3>[];
      final recreatedEngine = _engine(
        database,
        sent,
        downloadDirectory: () async => directory,
      );

      await recreatedEngine.handleFrame(
        _connection('peer-a'),
        _offerFrame(offer),
        requireCurrent: () {},
      );

      expect(await temp.length(), 0);
      final recovered = await database.fetchFileTransfer(transferId);
      expect(recovered?.committedBytes, 0);
      expect(recovered?.resumeProofResetCount, 1);
      final ready = sent.singleWhere(
        (frame) => frame.type == WhisperFrameType.fileReady,
      );
      expect(
        FileTransferV3Control.fromJson(
          jsonDecode(utf8.decode(ready.payload)) as Map<String, dynamic>,
        ).durableOffset,
        0,
      );
    });

    test('reset recovery survives failure after filesystem truncation',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('whisper-reset-fault-');
      addTearDown(() => directory.delete(recursive: true));
      final temp = File(await safeTransferTempPath(directory, transferId));
      await temp.parent.create(recursive: true);
      await temp.writeAsBytes(const <int>[1, 2, 3, 4]);
      final database = _FaultingResetDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final offer = _message(
        transferId: transferId,
        sender: 'peer-a',
        receiver: 'local',
        path: '',
        size: 8,
      );
      final message = await database.insertMessageReturning(offer);
      await database.upsertFileTransfer(_transfer(
        transferId: transferId,
        peerUid: 'peer-a',
        direction: FileTransferDirection.incoming,
        state: FileTransferState.negotiating,
        path: '',
        tempPath: temp.path,
        size: 8,
        committedBytes: 4,
        messageRowId: message.id,
      ));
      final firstSent = <WhisperFrameV3>[];
      final firstEngine = _engine(
        database,
        firstSent,
        downloadDirectory: () async => directory,
      );
      const mismatch = FileTransferV3Control(
        action: FileTransferV3Action.error,
        transferId: transferId,
        durableOffset: 4,
        size: 8,
        failureReason: FileTransferFailureReason.resumeProofMismatch,
      );

      await firstEngine.handleFrame(
        _connection('peer-a'),
        _controlFrame(mismatch),
        requireCurrent: () {},
      );
      expect(await temp.length(), 0);
      final pending = await database.fetchFileTransfer(transferId);
      expect(pending?.committedBytes, 4);
      expect(
        pending?.resumeProofResetCount,
        pendingResumeProofResetMarker,
      );
      expect(pending?.state, FileTransferState.negotiating);

      final recoveredSent = <WhisperFrameV3>[];
      final recreatedEngine = _engine(
        database,
        recoveredSent,
        downloadDirectory: () async => directory,
      );
      await recreatedEngine.handleFrame(
        _connection('peer-a'),
        _offerFrame(offer),
        requireCurrent: () {},
      );

      final recovered = await database.fetchFileTransfer(transferId);
      expect(recovered?.committedBytes, 0);
      expect(recovered?.resumeProofResetCount, 1);
      final ready = recoveredSent.singleWhere(
        (frame) => frame.type == WhisperFrameType.fileReady,
      );
      expect(
        FileTransferV3Control.fromJson(
          jsonDecode(utf8.decode(ready.payload)) as Map<String, dynamic>,
        ).durableOffset,
        0,
      );
    });

    test('reset recovery survives a real filesystem failure after claim',
        () async {
      final directory =
          await Directory.systemTemp.createTemp('whisper-reset-fs-fault-');
      addTearDown(() => directory.delete(recursive: true));
      final temp = File(await safeTransferTempPath(directory, transferId));
      await temp.parent.create(recursive: true);
      await temp.writeAsBytes(const <int>[1, 2, 3, 4]);
      final database = _ClaimFaultDatabase(
        NativeDatabase.memory(),
        onClaimed: () async {
          await temp.delete();
          await Directory(temp.path).create();
        },
      );
      addTearDown(database.close);
      final offer = _message(
        transferId: transferId,
        sender: 'peer-a',
        receiver: 'local',
        path: '',
        size: 8,
      );
      final message = await database.insertMessageReturning(offer);
      await database.upsertFileTransfer(_transfer(
        transferId: transferId,
        peerUid: 'peer-a',
        direction: FileTransferDirection.incoming,
        state: FileTransferState.negotiating,
        path: '',
        tempPath: temp.path,
        size: 8,
        committedBytes: 4,
        messageRowId: message.id,
      ));
      final firstEngine = _engine(
        database,
        <WhisperFrameV3>[],
        downloadDirectory: () async => directory,
      );
      const mismatch = FileTransferV3Control(
        action: FileTransferV3Action.error,
        transferId: transferId,
        durableOffset: 4,
        size: 8,
        failureReason: FileTransferFailureReason.resumeProofMismatch,
      );

      await firstEngine.handleFrame(
        _connection('peer-a'),
        _controlFrame(mismatch),
        requireCurrent: () {},
      );
      final pending = await database.fetchFileTransfer(transferId);
      expect(pending?.state, FileTransferState.negotiating);
      expect(pending?.committedBytes, 4);
      expect(
        pending?.resumeProofResetCount,
        pendingResumeProofResetMarker,
      );

      await Directory(temp.path).delete();
      final sent = <WhisperFrameV3>[];
      final recreatedEngine = _engine(
        database,
        sent,
        downloadDirectory: () async => directory,
      );
      await recreatedEngine.handleFrame(
        _connection('peer-a'),
        _offerFrame(offer),
        requireCurrent: () {},
      );

      final recovered = await database.fetchFileTransfer(transferId);
      expect(recovered?.state, FileTransferState.negotiating);
      expect(recovered?.committedBytes, 0);
      expect(recovered?.resumeProofResetCount, 1);
      expect(await File(temp.path).length(), 0);
      expect(
        sent.where((frame) => frame.type == WhisperFrameType.fileReady),
        hasLength(1),
      );
    });

    test('receiver rejects zero, stale, or non-durable mismatch offsets',
        () async {
      for (final item in <({int committed, int control, int tempLength})>[
        (committed: 0, control: 0, tempLength: 0),
        (committed: 4, control: 3, tempLength: 4),
        (committed: 4, control: 4, tempLength: 3),
      ]) {
        final directory =
            await Directory.systemTemp.createTemp('whisper-reset-invalid-');
        final temp = File(await safeTransferTempPath(directory, transferId));
        await temp.parent.create(recursive: true);
        await temp.writeAsBytes(Uint8List(item.tempLength));
        final database = LocalDatabase.forTesting(NativeDatabase.memory());
        final persistedMessage = await database.insertMessageReturning(
          _message(
            transferId: transferId,
            sender: 'peer-a',
            receiver: 'local',
            path: '',
            size: 8,
          ),
        );
        await database.upsertFileTransfer(
          _transfer(
            transferId: transferId,
            peerUid: 'peer-a',
            direction: FileTransferDirection.incoming,
            state: FileTransferState.negotiating,
            path: '',
            tempPath: temp.path,
            size: 8,
            committedBytes: item.committed,
            messageRowId: persistedMessage.id,
          ),
        );
        final sent = <WhisperFrameV3>[];
        final engine = _engine(
          database,
          sent,
          downloadDirectory: () async => directory,
        );
        final mismatch = FileTransferV3Control(
          action: FileTransferV3Action.error,
          transferId: transferId,
          durableOffset: item.control,
          size: 8,
          failureReason: FileTransferFailureReason.resumeProofMismatch,
        );

        await engine.handleFrame(
          _connection('peer-a'),
          _controlFrame(mismatch),
          requireCurrent: () {},
        );

        final stored = await database.fetchFileTransfer(transferId);
        expect(stored?.state, FileTransferState.failed);
        expect(stored?.resumeProofResetCount, 0);
        expect(await temp.length(), item.tempLength);
        expect(
          sent.where((frame) => frame.type == WhisperFrameType.fileReady),
          isEmpty,
        );
        await database.close();
        await directory.delete(recursive: true);
      }
    });
  });

  group('incoming integrity and publication', () {
    test('matching SHA publishes uniquely and commits paths before visibility',
        () async {
      const transferId = '11234567-89ab-4cde-8fab-0123456789ab';
      final root = await Directory.systemTemp.createTemp('whisper-receive-');
      addTearDown(() => root.delete(recursive: true));
      final original = File(p.join(root.path, 'report.pdf'));
      await original.writeAsString('keep me');
      final bytes = Uint8List.fromList(const <int>[1, 2, 3, 4]);
      final checksum = bytesChecksum(bytes, algorithm: 'sha256');
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final sent = <WhisperFrameV3>[];
      var visibilitySawCommittedPaths = false;
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
        notifyFileVisible: (path) async {
          final transfer = await database.fetchFileTransfer(transferId);
          final message = await database.fetchMessageByUuid(transferId);
          visibilitySawCommittedPaths =
              transfer?.state == FileTransferState.completed &&
                  transfer?.finalPath == path &&
                  message?.path == path;
        },
      );
      final offer = _message(
        transferId: transferId,
        sender: 'peer-a',
        receiver: 'local',
        path: '',
        size: bytes.length,
        name: 'report.pdf',
        checksum: checksum,
      );

      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(offer),
        requireCurrent: () {},
      );
      await engine.handleFrame(
        _connection('peer-a'),
        WhisperFrameV3(
          type: WhisperFrameType.fileData,
          transferId: transferId,
          offset: 0,
          sequence: 0,
          payload: bytes,
        ),
        requireCurrent: () {},
      );

      expect(await original.readAsString(), 'keep me');
      final transfer = await database.fetchFileTransfer(transferId);
      final message = await database.fetchMessageByUuid(transferId);
      final published = File(transfer!.finalPath);
      expect(p.basename(published.path), 'report-1.pdf');
      expect(await published.readAsBytes(), bytes);
      expect(transfer.state, FileTransferState.completed);
      expect(transfer.finalPath, published.path);
      expect(message?.path, published.path);
      expect(visibilitySawCommittedPaths, isTrue);
    });

    test('one-byte corruption fails integrity and deletes untrusted temp',
        () async {
      const transferId = '21234567-89ab-4cde-8fab-0123456789ab';
      final root = await Directory.systemTemp.createTemp('whisper-corrupt-');
      addTearDown(() => root.delete(recursive: true));
      final expected = Uint8List.fromList(const <int>[1, 2, 3, 4]);
      final corrupted = Uint8List.fromList(const <int>[1, 2, 3, 5]);
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final sent = <WhisperFrameV3>[];
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
        notifyFileVisible: (_) async => fail('corrupt file must not publish'),
      );
      final offer = _message(
        transferId: transferId,
        sender: 'peer-a',
        receiver: 'local',
        path: '',
        size: expected.length,
        checksum: bytesChecksum(expected, algorithm: 'sha256'),
      );

      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(offer),
        requireCurrent: () {},
      );
      final tempPath = (await database.fetchFileTransfer(transferId))!.tempPath;
      await engine.handleFrame(
        _connection('peer-a'),
        WhisperFrameV3(
          type: WhisperFrameType.fileData,
          transferId: transferId,
          offset: 0,
          sequence: 0,
          payload: corrupted,
        ),
        requireCurrent: () {},
      );

      expect(
        (await database.fetchFileTransfer(transferId))?.state,
        FileTransferState.failed,
      );
      expect(File(tempPath).existsSync(), isFalse);
      expect(File(p.join(root.path, 'payload.bin')).existsSync(), isFalse);
      final error = sent.lastWhere(
        (frame) => frame.type == WhisperFrameType.fileError,
      );
      final control = FileTransferV3Control.fromJson(
        jsonDecode(utf8.decode(error.payload)) as Map<String, dynamic>,
      );
      expect(control.errorCode, 'integrity');

      sent.clear();
      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(offer),
        requireCurrent: () {},
      );
      final replayedError = sent.singleWhere(
        (frame) => frame.type == WhisperFrameType.fileError,
      );
      expect(
        FileTransferV3Control.fromJson(
          jsonDecode(utf8.decode(replayedError.payload))
              as Map<String, dynamic>,
        ).errorCode,
        'integrity',
      );
    });

    test('a hash-to-publish temp swap is never published', () async {
      const transferId = '22234567-89ab-4cde-8fab-0123456789ab';
      final root = await Directory.systemTemp.createTemp('whisper-swap-');
      addTearDown(() => root.delete(recursive: true));
      final expected = Uint8List.fromList(const <int>[1, 2, 3, 4]);
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final sent = <WhisperFrameV3>[];
      var swapped = false;
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async {
          final transfer = await database.fetchFileTransfer(transferId);
          if (!swapped &&
              transfer?.state == FileTransferState.verifying &&
              transfer!.tempPath.isNotEmpty) {
            final original = File(transfer.tempPath);
            if (await original.exists() &&
                await original.length() == expected.length) {
              swapped = true;
              await original.rename('${original.path}.verified-original');
              await File(original.path).writeAsBytes(const <int>[1, 2, 3, 5]);
            }
          }
          return root;
        },
        notifyFileVisible: (_) async => fail('swapped temp must not publish'),
      );

      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(_message(
          transferId: transferId,
          sender: 'peer-a',
          receiver: 'local',
          path: '',
          size: expected.length,
          checksum: bytesChecksum(expected, algorithm: 'sha256'),
        )),
        requireCurrent: () {},
      );
      await engine.handleFrame(
        _connection('peer-a'),
        WhisperFrameV3(
          type: WhisperFrameType.fileData,
          transferId: transferId,
          offset: 0,
          sequence: 0,
          payload: expected,
        ),
        requireCurrent: () {},
      );

      expect(swapped, isTrue);
      expect(
        (await database.fetchFileTransfer(transferId))?.state,
        FileTransferState.failed,
      );
      expect(File(p.join(root.path, 'payload.bin')).existsSync(), isFalse);
    });

    test('candidate symlink replacement is rejected before the next write',
        () async {
      const transferId = '81234567-89ab-4cde-8fab-0123456789ab';
      final root = await Directory.systemTemp.createTemp('whisper-temp-link-');
      final outside =
          await Directory.systemTemp.createTemp('whisper-temp-link-outside-');
      addTearDown(() async {
        if (root.existsSync()) await root.delete(recursive: true);
        if (outside.existsSync()) await outside.delete(recursive: true);
      });
      final outsideFile = File(p.join(outside.path, 'outside.bin'));
      await outsideFile.writeAsBytes(const <int>[9]);
      final bytes = Uint8List.fromList(const <int>[1, 2, 3, 4]);
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final sent = <WhisperFrameV3>[];
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
      );

      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(_message(
          transferId: transferId,
          sender: 'peer-a',
          receiver: 'local',
          path: '',
          size: bytes.length,
          checksum: bytesChecksum(bytes, algorithm: 'sha256'),
        )),
        requireCurrent: () {},
      );
      final transfer = await database.fetchFileTransfer(transferId);
      final temp = File(transfer!.tempPath);
      await temp.delete();
      await Link(temp.path).create(outsideFile.path);

      await engine.handleFrame(
        _connection('peer-a'),
        WhisperFrameV3(
          type: WhisperFrameType.fileData,
          transferId: transferId,
          offset: 0,
          sequence: 0,
          payload: bytes,
        ),
        requireCurrent: () {},
      );

      expect(await outsideFile.readAsBytes(), const <int>[9]);
      expect(
        (await database.fetchFileTransfer(transferId))?.state,
        FileTransferState.failed,
      );
      expect(File(p.join(root.path, 'payload.bin')).existsSync(), isFalse);
    });

    test('matching tail proof never replaces the final full-file SHA',
        () async {
      const transferId = '91234567-89ab-4cde-8fab-0123456789ab';
      final root = await Directory.systemTemp.createTemp('whisper-tail-');
      addTearDown(() => root.delete(recursive: true));
      final expected = Uint8List(fileTransferV3ResumeProofWindowSize + 2)
        ..fillRange(0, fileTransferV3ResumeProofWindowSize + 2, 1);
      final prefixLength = expected.length - 1;
      final corruptedPrefix = Uint8List.fromList(
        expected.sublist(0, prefixLength),
      )..[0] = 2;
      final temp = File(await safeTransferTempPath(root, transferId));
      await temp.parent.create(recursive: true);
      await temp.writeAsBytes(corruptedPrefix);
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final offer = _message(
        transferId: transferId,
        sender: 'peer-a',
        receiver: 'local',
        path: '',
        size: expected.length,
        checksum: bytesChecksum(expected, algorithm: 'sha256'),
      );
      final persistedMessage = await database.insertMessageReturning(offer);
      await database.upsertFileTransfer(_transfer(
        transferId: transferId,
        peerUid: 'peer-a',
        direction: FileTransferDirection.incoming,
        state: FileTransferState.negotiating,
        path: '',
        tempPath: temp.path,
        size: expected.length,
        committedBytes: prefixLength,
        messageRowId: persistedMessage.id,
      ).copyWith(
          checksumValue: offer.content == null
              ? _emptySha256
              : FileTransferV3Metadata.parseOffer(
                  offer.content,
                  size: offer.size,
                ).checksumValue));
      final sent = <WhisperFrameV3>[];
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
        notifyFileVisible: (_) async => fail('corrupt prefix must not publish'),
      );

      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(offer),
        requireCurrent: () {},
      );
      final readyFrame = sent.singleWhere(
        (frame) => frame.type == WhisperFrameType.fileReady,
      );
      final ready = FileTransferV3Control.fromJson(
        jsonDecode(utf8.decode(readyFrame.payload)) as Map<String, dynamic>,
      );
      expect(ready.resumeProofLength, fileTransferV3ResumeProofWindowSize);
      expect(
        ready.resumeProofSha256,
        bytesChecksum(
          expected.sublist(
            prefixLength - fileTransferV3ResumeProofWindowSize,
            prefixLength,
          ),
          algorithm: 'sha256',
        ),
      );

      await engine.handleFrame(
        _connection('peer-a'),
        WhisperFrameV3(
          type: WhisperFrameType.fileData,
          transferId: transferId,
          offset: prefixLength,
          sequence: 0,
          payload: Uint8List.fromList(<int>[expected.last]),
        ),
        requireCurrent: () {},
      );
      expect(
        (await database.fetchFileTransfer(transferId))?.state,
        FileTransferState.failed,
      );
      expect(temp.existsSync(), isFalse);
    });

    test('zero-byte file verifies and publishes without a data frame',
        () async {
      const transferId = '31234567-89ab-4cde-8fab-0123456789ab';
      final root = await Directory.systemTemp.createTemp('whisper-empty-');
      addTearDown(() => root.delete(recursive: true));
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final sent = <WhisperFrameV3>[];
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
        notifyFileVisible: (_) async {},
      );

      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(_message(
          transferId: transferId,
          sender: 'peer-a',
          receiver: 'local',
          path: '',
          size: 0,
        )),
        requireCurrent: () {},
      );

      final published = File(p.join(root.path, 'payload.bin'));
      expect(published.existsSync(), isTrue);
      expect(await published.length(), 0);
      expect(
        (await database.fetchFileTransfer(transferId))?.state,
        FileTransferState.completed,
      );
      expect(
        sent.where((frame) => frame.type == WhisperFrameType.fileComplete),
        hasLength(1),
      );
    });

    test('timestamp failure removes only the reservation and retains temp',
        () async {
      const transferId = '41234567-89ab-4cde-8fab-0123456789ab';
      final root = await Directory.systemTemp.createTemp('whisper-timestamp-');
      addTearDown(() => root.delete(recursive: true));
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final sent = <WhisperFrameV3>[];
      var visibilityCalls = 0;
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
        setPublishedFileTimestamp: (_, __) async {
          throw const FileSystemException('timestamp failed');
        },
        notifyFileVisible: (_) async => visibilityCalls += 1,
      );
      final bytes = Uint8List.fromList(const <int>[1, 2, 3, 4]);
      final offer = _message(
        transferId: transferId,
        sender: 'peer-a',
        receiver: 'local',
        path: '',
        size: bytes.length,
        checksum: bytesChecksum(bytes, algorithm: 'sha256'),
        fileTimestamp: 1,
      );

      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(offer),
        requireCurrent: () {},
      );
      final tempPath = (await database.fetchFileTransfer(transferId))!.tempPath;
      await engine.handleFrame(
        _connection('peer-a'),
        WhisperFrameV3(
          type: WhisperFrameType.fileData,
          transferId: transferId,
          offset: 0,
          sequence: 0,
          payload: bytes,
        ),
        requireCurrent: () {},
      );

      expect(File(tempPath).existsSync(), isTrue);
      expect(File(p.join(root.path, 'payload.bin')).existsSync(), isFalse);
      expect(
        (await database.fetchFileTransfer(transferId))?.state,
        FileTransferState.failed,
      );
      expect(visibilityCalls, 0);
    });

    test(
        'database failure removes reservation, retains temp, and never notifies',
        () async {
      const transferId = '51234567-89ab-4cde-8fab-0123456789ab';
      final root = await Directory.systemTemp.createTemp('whisper-db-failure-');
      addTearDown(() => root.delete(recursive: true));
      final database = _FailingCompletionDatabase(NativeDatabase.memory());
      addTearDown(database.close);
      final sent = <WhisperFrameV3>[];
      var visibilityCalls = 0;
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
        notifyFileVisible: (_) async => visibilityCalls += 1,
      );
      final bytes = Uint8List.fromList(const <int>[1, 2, 3, 4]);
      final offer = _message(
        transferId: transferId,
        sender: 'peer-a',
        receiver: 'local',
        path: '',
        size: bytes.length,
        checksum: bytesChecksum(bytes, algorithm: 'sha256'),
      );

      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(offer),
        requireCurrent: () {},
      );
      final tempPath = (await database.fetchFileTransfer(transferId))!.tempPath;
      await engine.handleFrame(
        _connection('peer-a'),
        WhisperFrameV3(
          type: WhisperFrameType.fileData,
          transferId: transferId,
          offset: 0,
          sequence: 0,
          payload: bytes,
        ),
        requireCurrent: () {},
      );

      expect(File(tempPath).existsSync(), isTrue);
      expect(File(p.join(root.path, 'payload.bin')).existsSync(), isFalse);
      expect(
        (await database.fetchFileTransfer(transferId))?.state,
        FileTransferState.failed,
      );
      expect(visibilityCalls, 0);
    });

    test('visibility failure cannot block complete control or terminal cleanup',
        () async {
      const transferId = '61234567-89ab-4cde-8fab-0123456789ab';
      final root =
          await Directory.systemTemp.createTemp('whisper-notify-failure-');
      addTearDown(() => root.delete(recursive: true));
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final sent = <WhisperFrameV3>[];
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
        notifyFileVisible: (_) async => throw StateError('visibility failed'),
      );
      final bytes = Uint8List.fromList(const <int>[1, 2, 3, 4]);

      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(_message(
          transferId: transferId,
          sender: 'peer-a',
          receiver: 'local',
          path: '',
          size: bytes.length,
          checksum: bytesChecksum(bytes, algorithm: 'sha256'),
        )),
        requireCurrent: () {},
      );
      await engine.handleFrame(
        _connection('peer-a'),
        WhisperFrameV3(
          type: WhisperFrameType.fileData,
          transferId: transferId,
          offset: 0,
          sequence: 0,
          payload: bytes,
        ),
        requireCurrent: () {},
      );

      expect(
        (await database.fetchFileTransfer(transferId))?.state,
        FileTransferState.completed,
      );
      expect(
        sent.where((frame) => frame.type == WhisperFrameType.fileComplete),
        hasLength(1),
      );
    });
  });

  group('incoming offer admission', () {
    test('invalid offer fields return stable reasons without persistence',
        () async {
      final root = await Directory.systemTemp.createTemp('whisper-invalid-');
      addTearDown(() => root.delete(recursive: true));
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final sent = <WhisperFrameV3>[];
      var acknowledgements = 0;
      var dispatches = 0;
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
        ackMessage: (_) => acknowledgements += 1,
        dispatchOutgoingMessage: (_) => dispatches += 1,
      );
      final valid = _message(
        transferId: '71234567-89ab-4cde-8fab-0123456789ab',
        sender: 'peer-a',
        receiver: 'local',
        path: '',
        size: 1,
        checksum: bytesChecksum(const <int>[1], algorithm: 'sha256'),
      );
      final cases = <({MessageData message, String reason})>[
        (message: valid.copyWith(name: '../escape'), reason: 'invalid_name'),
        (
          message: valid.copyWith(
            uuid: '76234567-89ab-4cde-8fab-0123456789ab',
            name: String.fromCharCode(0xd800),
          ),
          reason: 'invalid_name',
        ),
        (
          message: valid.copyWith(
            uuid: '72234567-89ab-4cde-8fab-0123456789ab',
            path: '/private/source',
          ),
          reason: 'invalid_path',
        ),
        (
          message: valid.copyWith(
            uuid: '73234567-89ab-4cde-8fab-0123456789ab',
            size: -1,
          ),
          reason: 'invalid_size',
        ),
        (
          message: valid.copyWith(
            uuid: '74234567-89ab-4cde-8fab-0123456789ab',
            content: Value<String?>(jsonEncode(<String, Object>{
              ...const FileTransferV3Metadata(checksumValue: _emptySha256)
                  .toJson(),
              'checksumAlgorithm': 'none',
            })),
          ),
          reason: 'invalid_metadata',
        ),
      ];

      for (final item in cases) {
        await engine.handleFrame(
          _connection('peer-a'),
          _offerFrame(item.message),
          requireCurrent: () {},
        );
        final errorFrame = sent.removeLast();
        final control = FileTransferV3Control.fromJson(
          jsonDecode(utf8.decode(errorFrame.payload)) as Map<String, dynamic>,
        );
        expect(control.errorCode, item.reason);
        expect(await database.fetchFileTransfer(item.message.uuid), isNull);
        expect(await database.fetchMessageByUuid(item.message.uuid), isNull);
      }
      expect((acknowledgements, dispatches), (0, 0));
      expect(Directory(p.join(root.path, '.whisper')).existsSync(), isFalse);
    });

    test(
        'the 33rd peer offer returns queue_full before every local side effect',
        () async {
      const transferId = '41234567-89ab-4cde-8fab-0123456789ab';
      final root = await Directory.systemTemp.createTemp('whisper-quota-');
      addTearDown(() => root.delete(recursive: true));
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      for (var index = 0; index < maxNonterminalTransfersPerPeer; index += 1) {
        final id =
            '40000000-0000-4000-8000-${index.toRadixString(16).padLeft(12, '0')}';
        await database.upsertFileTransfer(_transfer(
          transferId: id,
          peerUid: 'peer-a',
          direction: index.isEven
              ? FileTransferDirection.incoming
              : FileTransferDirection.outgoing,
          state: FileTransferState.queued,
          path: '',
          size: 1,
        ));
      }
      final sent = <WhisperFrameV3>[];
      var acknowledgements = 0;
      var dispatches = 0;
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
        ackMessage: (_) => acknowledgements += 1,
        dispatchOutgoingMessage: (_) => dispatches += 1,
      );
      final offer = _message(
        transferId: transferId,
        sender: 'peer-a',
        receiver: 'local',
        path: '',
        size: 1,
        checksum: bytesChecksum(const <int>[1], algorithm: 'sha256'),
      );

      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(offer),
        requireCurrent: () {},
      );

      expect(await database.fetchFileTransfer(transferId), isNull);
      expect(await database.fetchMessageByUuid(transferId), isNull);
      expect((acknowledgements, dispatches), (0, 0));
      expect(Directory(p.join(root.path, '.whisper')).existsSync(), isFalse);
      final errorFrame = sent.singleWhere(
        (frame) => frame.type == WhisperFrameType.fileError,
      );
      expect(
        FileTransferV3Control.fromJson(
          jsonDecode(utf8.decode(errorFrame.payload)) as Map<String, dynamic>,
        ).errorCode,
        'queue_full',
      );
    });

    test('the 129th global offer returns queue_full', () async {
      const transferId = '81234567-89ab-4cde-8fab-0123456789ab';
      final root = await Directory.systemTemp.createTemp('whisper-global-');
      addTearDown(() => root.delete(recursive: true));
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      for (var index = 0; index < maxNonterminalTransfersGlobal; index += 1) {
        final id =
            '80000000-0000-4000-8000-${index.toRadixString(16).padLeft(12, '0')}';
        await database.upsertFileTransfer(_transfer(
          transferId: id,
          peerUid: 'peer-${index % 8}',
          direction: index.isEven
              ? FileTransferDirection.incoming
              : FileTransferDirection.outgoing,
          state: FileTransferState.queued,
          path: '',
          size: 1,
        ));
      }
      final sent = <WhisperFrameV3>[];
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
      );

      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(_message(
          transferId: transferId,
          sender: 'peer-a',
          receiver: 'local',
          path: '',
          size: 1,
          checksum: bytesChecksum(const <int>[1], algorithm: 'sha256'),
        )),
        requireCurrent: () {},
      );

      expect(await database.fetchFileTransfer(transferId), isNull);
      expect(await database.fetchMessageByUuid(transferId), isNull);
      final error = sent.singleWhere(
        (frame) => frame.type == WhisperFrameType.fileError,
      );
      expect(
        FileTransferV3Control.fromJson(
          jsonDecode(utf8.decode(error.payload)) as Map<String, dynamic>,
        ).errorCode,
        'queue_full',
      );
    });

    test('stale session completes the DB invariant and duplicate resumes later',
        () async {
      const transferId = '51234567-89ab-4cde-8fab-0123456789ab';
      final root = await Directory.systemTemp.createTemp('whisper-slow-offer-');
      addTearDown(() => root.delete(recursive: true));
      var current = true;
      final database = _AdmissionNotifyingDatabase(
        NativeDatabase.memory(),
        onAdmitted: () => current = false,
      );
      addTearDown(database.close);
      final sent = <WhisperFrameV3>[];
      var acknowledgements = 0;
      var dispatches = 0;
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
        ackMessage: (_) => acknowledgements += 1,
        dispatchOutgoingMessage: (_) => dispatches += 1,
      );
      final offer = _message(
        transferId: transferId,
        sender: 'peer-a',
        receiver: 'local',
        path: '',
        size: 1,
        checksum: bytesChecksum(const <int>[1], algorithm: 'sha256'),
      );
      void requireCurrent() {
        if (!current) throw StateError('stale generation');
      }

      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(offer),
        requireCurrent: requireCurrent,
      );
      final claimedTransfer = await database.fetchFileTransfer(transferId);
      expect(claimedTransfer, isNotNull);
      expect(await database.fetchMessageByUuid(transferId), isNotNull);
      expect(claimedTransfer?.tempPath, isEmpty);
      expect((acknowledgements, dispatches, sent.length), (0, 0, 0));
      expect(Directory(p.join(root.path, '.whisper')).existsSync(), isFalse);

      current = true;
      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(offer),
        requireCurrent: requireCurrent,
      );
      expect((acknowledgements, dispatches), (1, 1));
      expect(
        sent.where((frame) => frame.type == WhisperFrameType.fileReady),
        hasLength(1),
      );
      expect(
        (await database.fetchFileTransfer(transferId))?.tempPath,
        isNotEmpty,
      );
    });

    test('a duplicate offer after message deletion returns a stable error',
        () async {
      const transferId = '91234567-89ab-4cde-8fab-0123456789ab';
      final root =
          await Directory.systemTemp.createTemp('whisper-deleted-offer-');
      addTearDown(() => root.delete(recursive: true));
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final sent = <WhisperFrameV3>[];
      final engine = _engine(
        database,
        sent,
        downloadDirectory: () async => root,
      );
      final offer = _message(
        transferId: transferId,
        sender: 'peer-a',
        receiver: 'local',
        path: '',
        size: 1,
        checksum: bytesChecksum(const <int>[1], algorithm: 'sha256'),
      );
      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(offer),
        requireCurrent: () {},
      );
      final message = await database.fetchMessageByUuid(transferId);
      expect(message, isNotNull);
      await database.deleteMessage(message!.id);
      sent.clear();

      await engine.handleFrame(
        _connection('peer-a'),
        _offerFrame(offer),
        requireCurrent: () {},
      );

      final error = sent.singleWhere(
        (frame) => frame.type == WhisperFrameType.fileError,
      );
      expect(
        FileTransferV3Control.fromJson(
          jsonDecode(utf8.decode(error.payload)) as Map<String, dynamic>,
        ).errorCode,
        'message_missing',
      );
      final transfer = await database.fetchFileTransfer(transferId);
      expect(transfer?.messageRowId, 0);
      expect(transfer?.state, FileTransferState.canceled);
      expect(await database.fetchMessagesByUuid(transferId), isEmpty);
    });
  });

  group('failure privacy', () {
    test('remote detail never reaches persistence, snapshots, or notices',
        () async {
      const transferId = '81234567-89ab-4cde-8fab-0123456789ab';
      const secret = 'token=never-log-this /Users/alice/Documents/private.txt';
      final database = LocalDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);
      final message = await database.insertMessageReturning(_message(
        transferId: transferId,
        sender: 'local',
        receiver: 'peer-a',
        path: '/local/source.bin',
        size: 4,
      ));
      await database.upsertFileTransfer(_transfer(
        transferId: transferId,
        peerUid: 'peer-a',
        direction: FileTransferDirection.outgoing,
        state: FileTransferState.transferring,
        path: '/local/source.bin',
        size: 4,
        messageRowId: message.id,
      ));
      final notices = <String>[];
      final snapshots = <TransferSnapshot>[];
      final engine = _engine(
        database,
        <WhisperFrameV3>[],
        notify: notices.add,
        emitTransferUpdated: snapshots.add,
      );
      final payload = <String, Object?>{
        'protocolVersion': fileTransferV3ProtocolVersion,
        'action': FileTransferV3Action.error.name,
        'transferId': transferId,
        'durableOffset': 0,
        'size': 4,
        'errorCode': 'source',
        'errorMessage': secret,
        'resumeProofSha256': '',
        'resumeProofLength': 0,
      };

      await engine.handleFrame(
        _connection('peer-a'),
        WhisperFrameV3(
          type: WhisperFrameType.fileError,
          transferId: transferId,
          offset: 0,
          sequence: 0,
          payload: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
        ),
        requireCurrent: () {},
      );

      final stored = await database.fetchFileTransfer(transferId);
      expect(stored?.state, FileTransferState.failed);
      expect(stored?.lastError, FileTransferFailureReason.source.wireCode);
      expect(notices, <String>[FileTransferFailureReason.source.wireCode]);
      expect(
          snapshots.last.lastError, FileTransferFailureReason.source.wireCode);
      expect(jsonEncode(stored?.toJson()), isNot(contains(secret)));
      expect(jsonEncode(notices), isNot(contains(secret)));
    });
  });
}

MessageData _message({
  required String transferId,
  required String sender,
  required String receiver,
  required String path,
  required int size,
  String name = 'payload.bin',
  String checksum = _emptySha256,
  int? fileTimestamp,
}) =>
    MessageData(
      id: 0,
      sender: sender,
      receiver: receiver,
      name: name,
      clipboard: false,
      size: size,
      type: MessageEnum.File,
      content: jsonEncode(
        FileTransferV3Metadata(checksumValue: checksum).toJson(),
      ),
      message: '',
      timestamp: 1,
      uuid: transferId,
      acked: false,
      path: path,
      md5: '',
      fileTimestamp: fileTimestamp,
    );

FileTransferData _transfer({
  required String transferId,
  required String peerUid,
  required FileTransferDirection direction,
  required FileTransferState state,
  required String path,
  String tempPath = '',
  required int size,
  int committedBytes = 0,
  int messageRowId = 0,
  int resumeProofResetCount = 0,
}) =>
    FileTransferData(
      transferId: transferId,
      messageUuid: transferId,
      messageRowId: messageRowId,
      peerUid: peerUid,
      direction: direction,
      state: state,
      finalPath: path,
      tempPath: tempPath,
      size: size,
      checksumAlgorithm: 'sha256',
      checksumValue: _emptySha256,
      chunkSize: fileTransferV3FramePayloadSize,
      committedBytes: committedBytes,
      resumeProofResetCount: resumeProofResetCount,
      lastError: '',
      createdAt: 1,
      updatedAt: 1,
    );

FileTransferEngine _engine(
  LocalDatabase database,
  List<WhisperFrameV3> sent, {
  Future<Directory> Function()? downloadDirectory,
  Future<void> Function(String path)? notifyFileVisible,
  Future<void> Function(File file, int timestamp)? setPublishedFileTimestamp,
  FutureOr<void> Function(MessageData message)? ackMessage,
  void Function(MessageData message)? dispatchOutgoingMessage,
  void Function(String message)? notify,
  void Function(TransferSnapshot snapshot)? emitTransferUpdated,
}) =>
    FileTransferEngine(
      currentConnectionBinding: (peerId) =>
          TransferConnectionBinding(peerId: peerId, generation: 1),
      sendBytesToConnection: (_, bytes) {
        sent.add(WhisperFrameV3.decode(bytes as Uint8List));
        return true;
      },
      markPeerUnresponsive: (_) => false,
      emitTransferUpdated: emitTransferUpdated ?? (_) {},
      notify: notify ?? (_) {},
      remoteProfileFor: (_) => null,
      isConnectedTo: (_) => true,
      connectedPeerIds: () => const <String>{'peer-a'},
      defaultPeerId: () => '',
      hasLegacySinkFor: (_) => false,
      localPeerIdFor: (_) => 'local',
      buildMessage: (type, content, msg, fileName, size, clipboard,
              {md5 = '', path = '', uid, fileTimestamp, receiverOverride}) =>
          throw UnimplementedError(),
      dispatchOutgoingMessage: dispatchOutgoingMessage ?? (_) {},
      ackMessage: ackMessage ?? (_) {},
      wireMessageReplayGuard: WireMessageReplayGuard(),
      downloadDirectory: downloadDirectory,
      notifyFileVisible: notifyFileVisible,
      setPublishedFileTimestamp: setPublishedFileTimestamp,
      database: () => database,
    );

final class _FailingCompletionDatabase extends LocalDatabase {
  _FailingCompletionDatabase(QueryExecutor executor)
      : super.forTesting(executor);

  @override
  Future<FileTransferData> completeIncomingFileTransfer({
    required String transferId,
    required String finalPath,
    required int size,
  }) {
    throw StateError('injected completion failure');
  }
}

final class _AdmissionNotifyingDatabase extends LocalDatabase {
  _AdmissionNotifyingDatabase(
    QueryExecutor executor, {
    required this.onAdmitted,
  }) : super.forTesting(executor);

  final void Function() onAdmitted;

  @override
  Future<FileTransferAdmissionResult> admitFileTransfer({
    required MessageData message,
    required FileTransferData transfer,
    bool acked = false,
    int perPeerLimit = maxNonterminalTransfersPerPeer,
    int globalLimit = maxNonterminalTransfersGlobal,
  }) async {
    final result = await super.admitFileTransfer(
      message: message,
      transfer: transfer,
      acked: acked,
      perPeerLimit: perPeerLimit,
      globalLimit: globalLimit,
    );
    if (result.decision == FileTransferAdmission.admitted) {
      onAdmitted();
    }
    return result;
  }
}

final class _FaultingResetDatabase extends LocalDatabase {
  _FaultingResetDatabase(QueryExecutor executor) : super.forTesting(executor);

  var _failNextCompletion = true;

  @override
  Future<FileTransferData?> completeIncomingResumeProofReset(
    String transferId, {
    required int expectedOffset,
  }) {
    if (_failNextCompletion) {
      _failNextCompletion = false;
      throw StateError('injected reset completion failure');
    }
    return super.completeIncomingResumeProofReset(
      transferId,
      expectedOffset: expectedOffset,
    );
  }
}

final class _ClaimFaultDatabase extends LocalDatabase {
  _ClaimFaultDatabase(
    QueryExecutor executor, {
    required this.onClaimed,
  }) : super.forTesting(executor);

  final Future<void> Function() onClaimed;
  var _faulted = false;

  @override
  Future<FileTransferData?> claimIncomingResumeProofReset(
    String transferId, {
    required int expectedOffset,
  }) async {
    final claimed = await super.claimIncomingResumeProofReset(
      transferId,
      expectedOffset: expectedOffset,
    );
    if (claimed != null && !_faulted) {
      _faulted = true;
      await onClaimed();
    }
    return claimed;
  }
}

WhisperFrameV3 _offerFrame(MessageData message) => WhisperFrameV3(
      type: WhisperFrameType.fileOffer,
      transferId: message.uuid,
      offset: 0,
      sequence: 0,
      payload: Uint8List.fromList(utf8.encode(encodeWireMessage(message))),
    );

WhisperFrameV3 _controlFrame(FileTransferV3Control control) => WhisperFrameV3(
      type: switch (control.action) {
        FileTransferV3Action.ready => WhisperFrameType.fileReady,
        FileTransferV3Action.ack => WhisperFrameType.fileAck,
        FileTransferV3Action.complete => WhisperFrameType.fileComplete,
        FileTransferV3Action.cancel => WhisperFrameType.fileCancel,
        FileTransferV3Action.error => WhisperFrameType.fileError,
      },
      transferId: control.transferId,
      offset: control.durableOffset,
      sequence: 0,
      payload: Uint8List.fromList(utf8.encode(jsonEncode(control.toJson()))),
    );
