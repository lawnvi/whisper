import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/helper/folder_transfer_store.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/file_transfer_engine.dart';
import 'package:whisper/socket/file_transfer_v3.dart';
import 'package:whisper/socket/folder_transfer_manifest.dart';
import 'package:whisper/socket/folder_transfer_scan.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/transfer_ack_watchdog.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';
import 'package:whisper/socket/wire_message_replay.dart';
import 'package:whisper/state/peer_profile.dart';

const int _kib = 1024;

/// One device in a two-device setup: its own database, download folder and
/// engine, with frames carried to the other device in order.
final class _Device {
  _Device(
    this.uid,
    Directory temp, {
    this.scanFolder,
    this.ackTimeout,
    this.keepAliveInterval = const Duration(seconds: 5),
    this.quietLimit = const Duration(minutes: 5),
    this.checkpointInterval = const Duration(milliseconds: 30),
    this.ackIntervalSize = 512 * _kib,
    this.availableBytes,
  }) : downloads = Directory(p.join(temp.path, '$uid-downloads'))..createSync(),
       storeDirectory = Directory(p.join(temp.path, '$uid-store'));

  final String uid;
  final Directory downloads;
  final Directory storeDirectory;
  final Future<FolderScanResult> Function(String path)? scanFolder;

  /// How long this device waits for progress on what it sent.
  final Duration? ackTimeout;
  final Duration keepAliveInterval;
  final Duration quietLimit;
  final Duration checkpointInterval;
  final int ackIntervalSize;

  /// Free space this device reports for its download folder.
  final int? availableBytes;
  int unresponsiveVerdicts = 0;
  final LocalDatabase database = LocalDatabase.forTesting(
    NativeDatabase.memory(),
  );
  final List<TransferSnapshot> snapshots = <TransferSnapshot>[];
  final List<String> notices = <String>[];
  final List<MessageData> messages = <MessageData>[];
  final List<WhisperFrameV3> sent = <WhisperFrameV3>[];
  final List<Object> rejections = <Object>[];

  late final _Device other;
  late final FolderTransferStore store = FolderTransferStore(
    directory: () async => storeDirectory,
  );
  bool linked = true;
  int generation = 1;
  Future<void> _delivery = Future<void>.value();

  /// Called with each frame about to leave; return false to lose it.
  bool Function(WhisperFrameV3 frame)? onSend;

  /// Awaited before a frame is handed to the other device. Frames arrive in
  /// order, so holding one holds those behind it.
  Future<void> Function(WhisperFrameV3 frame)? beforeDeliver;

  TransferConnectionBinding get _bindingToOther =>
      TransferConnectionBinding(peerId: other.uid, generation: generation);

  late final FileTransferEngine engine = FileTransferEngine(
    currentConnectionBinding: (_) => linked ? _bindingToOther : null,
    authenticatedIdentityHashForConnection: (_) => null,
    sendBytesToConnection: (binding, bytes) {
      if (!linked || binding != _bindingToOther) return false;
      final frame = WhisperFrameV3.decode(
        Uint8List.fromList(bytes as Uint8List),
      );
      if (onSend?.call(frame) == false) return true;
      sent.add(frame);
      final receiver = other;
      final receiverBinding = TransferConnectionBinding(
        peerId: uid,
        generation: receiver.generation,
      );
      _delivery = _delivery.then((_) async {
        await beforeDeliver?.call(frame);
        if (!receiver.linked ||
            receiver.generation != receiverBinding.generation) {
          return;
        }
        try {
          await receiver.engine.handleFrame(
            receiverBinding,
            frame,
            requireCurrent: () {},
          );
        } catch (error) {
          receiver.rejections.add(error);
        }
      });
      return true;
    },
    markPeerUnresponsive: (_) {
      unresponsiveVerdicts += 1;
      return false;
    },
    ackWatchdog: ackTimeout == null
        ? null
        : TransferAckWatchdog(timeout: ackTimeout!),
    emitTransferUpdated: snapshots.add,
    notify: notices.add,
    remoteProfileFor: (peerId) => _profile(peerId),
    isConnectedTo: (_) => linked,
    connectedPeerIds: () => linked ? <String>{other.uid} : <String>{},
    defaultPeerId: () => '',
    hasLegacySinkFor: (_) => false,
    localPeerIdFor: (_) => uid,
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
          fileTimestamp = 0,
          receiverOverride,
        }) => MessageData(
          id: 0,
          sender: this.uid,
          receiver: receiverOverride ?? other.uid,
          name: fileName as String,
          clipboard: clipboard,
          size: size,
          type: type,
          content: content,
          message: msg as String,
          timestamp: 1,
          uuid: uid as String,
          acked: false,
          path: path as String,
          md5: md5,
          fileTimestamp: fileTimestamp as int?,
        ),
    dispatchOutgoingMessage: messages.add,
    ackMessage: (_) {},
    wireMessageReplayGuard: WireMessageReplayGuard(),
    downloadDirectory: () async => downloads,
    availableBytesForDownloadPath: (_) async => availableBytes,
    notifyFileVisible: (_) async {},
    // The smallest flow the protocol allows, so ten megabytes already go
    // through several windows.
    flowLimits: FileTransferV3FlowParameters(
      chunkSize: 512 * _kib,
      ackIntervalSize: ackIntervalSize,
      windowSize: 4096 * _kib,
    ),
    folderStore: store,
    scanFolder: scanFolder,
    folderCheckpointInterval: checkpointInterval,
    folderKeepAliveInterval: keepAliveInterval,
    folderQuietLimit: quietLimit,
    database: () => database,
  );

  Future<void> disconnect() async {
    linked = false;
    await engine.handlePeerDisconnected(other.uid);
  }

  void reconnect() {
    generation += 1;
    linked = true;
  }

  Future<FileTransferData> waitForState(
    String transferId,
    FileTransferState state, {
    int? skippedEntries,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final deadline = DateTime.now().add(timeout);
    FileTransferData? latest;
    while (DateTime.now().isBefore(deadline)) {
      latest = await database.fetchFileTransfer(transferId);
      if (latest?.state == state &&
          (skippedEntries == null ||
              latest?.skippedEntries == skippedEntries)) {
        return latest!;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail(
      '$uid: transfer $transferId is ${latest?.state} '
      '(${latest?.lastError}, skipped ${latest?.skippedEntries}), '
      'expected $state',
    );
  }

  Future<void> dispose() async {
    await engine.closeAll(persistRecoverable: false);
    await database.close();
  }
}

PeerProfile _profile(String uid) => PeerProfile(
  device: DeviceData(
    id: 0,
    uid: uid,
    name: uid,
    host: '192.168.1.2',
    port: 10002,
    password: '',
    platform: 'linux',
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

Uint8List _pattern(int length, int seed) {
  final random = math.Random(seed);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

void _writeTree(Directory root, Map<String, List<int>> files) {
  for (final entry in files.entries) {
    final file = File(p.join(root.path, entry.key));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(entry.value);
  }
}

Map<String, String> _snapshot(Directory root) {
  final result = <String, String>{};
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    final relative = p
        .relative(entity.path, from: root.path)
        .replaceAll(r'\', '/');
    if (entity is Directory) {
      result['$relative/'] = '';
    } else if (entity is File) {
      result[relative] = sha256.convert(entity.readAsBytesSync()).toString();
    }
  }
  return result;
}

String _onlyTransferId(_Device device) => device.messages.single.uuid;

void main() {
  late Directory temp;
  late Directory source;
  late _Device sender;
  late _Device receiver;

  void connect({
    Future<FolderScanResult> Function(String path)? scanFolder,
    Duration? ackTimeout,
    Duration keepAliveInterval = const Duration(seconds: 5),
    Duration quietLimit = const Duration(minutes: 5),
    Duration checkpointInterval = const Duration(milliseconds: 30),
    int ackIntervalSize = 512 * _kib,
    int? receiverAvailableBytes,
  }) {
    sender = _Device(
      'sender',
      temp,
      scanFolder: scanFolder,
      ackTimeout: ackTimeout,
      quietLimit: quietLimit,
      ackIntervalSize: ackIntervalSize,
    );
    receiver = _Device(
      'receiver',
      temp,
      keepAliveInterval: keepAliveInterval,
      checkpointInterval: checkpointInterval,
      ackIntervalSize: ackIntervalSize,
      availableBytes: receiverAvailableBytes,
    );
    sender.other = receiver;
    receiver.other = sender;
    addTearDown(() async {
      await sender.dispose();
      await receiver.dispose();
    });
  }

  setUp(() {
    temp = Directory.systemTemp.createTempSync('whisper-folder-engine-');
    source = Directory(p.join(temp.path, 'Project Files'))..createSync();
    addTearDown(() => temp.deleteSync(recursive: true));
  });

  Map<String, List<int>> sampleTree() => <String, List<int>>{
    'readme.txt': utf8.encode('hello'),
    'empty.bin': const <int>[],
    'docs/guide.md': _pattern(3000, 1),
    'docs/deep/nested/data.bin': _pattern(70000, 2),
    'media/clip.bin': _pattern(9000 * _kib, 3),
    for (var index = 0; index < 200; index += 1)
      'small/part${index % 7}/f$index.dat': _pattern(50 + index, 100 + index),
  };

  test('a folder arrives as one transfer with its structure intact', () async {
    _writeTree(source, sampleTree());
    Directory(
      p.join(source.path, 'hollow', 'inner'),
    ).createSync(recursive: true);
    connect();

    expect(
      await sender.engine.sendFolderTo('receiver', source.path),
      FolderSendOutcome.sent,
    );
    final transferId = _onlyTransferId(sender);
    final sent = await sender.waitForState(
      transferId,
      FileTransferState.completed,
    );
    final received = await receiver.waitForState(
      transferId,
      FileTransferState.completed,
    );

    final published = Directory(
      p.join(receiver.downloads.resolveSymbolicLinksSync(), 'Project Files'),
    );
    expect(p.equals(received.finalPath, published.path), isTrue);
    expect(_snapshot(published), _snapshot(source));
    expect(sent.skippedEntries ?? 0, 0);
    expect(received.skippedEntries ?? 0, 0);
    expect(sender.notices, isEmpty);
    expect(receiver.notices, isEmpty);
    expect(sender.rejections, isEmpty);
    expect(receiver.rejections, isEmpty);

    // One message and one transfer row on each side, however many files.
    final offer = sender.messages.single;
    expect(offer.type, MessageEnum.File);
    expect(offer.name, 'Project Files');
    final metadata = FileTransferV3Metadata.parseOffer(
      offer.content,
      size: offer.size,
    );
    expect(metadata.folder!.fileCount, sampleTree().length);
    expect(metadata.checksumAlgorithm, isNot(fileTransferV3ChecksumAlgorithm));
    expect(receiver.messages.single.uuid, transferId);
    expect(
      (await receiver.database.fetchMessageByUuid(transferId))!.path,
      received.finalPath,
    );

    // Nothing is left behind once the folder is published.
    expect(
      Directory(
        p.join(receiver.downloads.path, '.whisper', 'transfers'),
      ).listSync(),
      isEmpty,
    );
    final manifest = File(await sender.store.manifestPath(transferId));
    for (
      var attempt = 0;
      attempt < 200 && manifest.existsSync();
      attempt += 1
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(manifest.existsSync(), isFalse);

    // The stream went out in several windows, acknowledged along the way.
    expect(
      receiver.sent
          .where((frame) => frame.type == WhisperFrameType.fileAck)
          .length,
      greaterThan(2),
    );
    final progress = receiver.snapshots
        .where((snapshot) => snapshot.state == FileTransferState.transferring)
        .map((snapshot) => snapshot.committedBytes)
        .toList();
    expect(progress, isNotEmpty);
    for (var index = 1; index < progress.length; index += 1) {
      expect(progress[index], greaterThanOrEqualTo(progress[index - 1]));
    }

    // Both ends can show how many files are through, and it only goes up.
    for (final device in <_Device>[sender, receiver]) {
      final counts = device.snapshots
          .where((snapshot) => snapshot.state == FileTransferState.transferring)
          .map((snapshot) => snapshot.filesDone)
          .whereType<int>()
          .toList();
      expect(counts, isNotEmpty, reason: device.uid);
      expect(counts.last, lessThanOrEqualTo(sampleTree().length));
      for (var index = 1; index < counts.length; index += 1) {
        expect(
          counts[index],
          greaterThanOrEqualTo(counts[index - 1]),
          reason: device.uid,
        );
      }
    }
    expect(sent.state, FileTransferState.completed);
  });

  test('a taken name gets a suffix instead of being merged into', () async {
    _writeTree(source, <String, List<int>>{
      'a.txt': <int>[1],
    });
    connect();
    final existing = Directory(p.join(receiver.downloads.path, 'Project Files'))
      ..createSync();
    File(p.join(existing.path, 'mine.txt')).writeAsBytesSync(<int>[9]);

    await sender.engine.sendFolderTo('receiver', source.path);
    final transferId = _onlyTransferId(sender);
    final received = await receiver.waitForState(
      transferId,
      FileTransferState.completed,
    );

    expect(p.basename(received.finalPath), 'Project Files-1');
    expect(_snapshot(Directory(received.finalPath)).keys, <String>['a.txt']);
    expect(_snapshot(existing).keys, <String>['mine.txt']);
  });

  test('files that cannot be sent are counted, the rest arrives', () async {
    final tree = sampleTree();
    _writeTree(source, tree);
    if (!Platform.isWindows) {
      Link(p.join(source.path, 'shortcut')).createSync(temp.path);
    }
    connect(
      scanFolder: (path) async {
        final scan = scanFolderForTransfer(path);
        // Gone between the scan and the moment its bytes are due.
        File(p.join(path, 'docs', 'guide.md')).deleteSync();
        return scan;
      },
    );

    await sender.engine.sendFolderTo('receiver', source.path);
    final transferId = _onlyTransferId(sender);
    await sender.waitForState(
      transferId,
      FileTransferState.completed,
      skippedEntries: 1,
    );
    final received = await receiver.waitForState(
      transferId,
      FileTransferState.completed,
      skippedEntries: 1,
    );

    final arrived = _snapshot(Directory(received.finalPath));
    expect(arrived.containsKey('docs/guide.md'), isFalse);
    expect(arrived, _snapshot(source));
    expect(
      (await receiver.store.readSkipped(transferId)).single.reason,
      FolderSkipReason.sourceUnavailable,
    );
    final senderSkipped = await sender.store.readSkipped(transferId);
    expect(
      senderSkipped.map((entry) => entry.path),
      containsAll(<String>[
        'docs/guide.md',
        if (!Platform.isWindows) 'shortcut',
      ]),
    );
    final metadata = FileTransferV3Metadata.parseOffer(
      sender.messages.single.content,
      size: sender.messages.single.size,
    );
    expect(metadata.folder!.skippedAtSource, Platform.isWindows ? 0 : 1);
    expect(
      sender.snapshots.last.skippedEntries,
      1,
      reason: 'the conversation is told once the receiver reports the count',
    );
  });

  test('an interrupted folder continues where it stopped', () async {
    _writeTree(source, sampleTree());
    connect();
    var dataFrames = 0;
    final interrupted = Completer<void>();
    sender.onSend = (frame) {
      if (frame.type == WhisperFrameType.fileData && ++dataFrames == 3) {
        interrupted.complete();
        return false;
      }
      return !interrupted.isCompleted;
    };

    await sender.engine.sendFolderTo('receiver', source.path);
    final transferId = _onlyTransferId(sender);
    await interrupted.future;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await sender.disconnect();
    await receiver.disconnect();
    final paused = await receiver.waitForState(
      transferId,
      FileTransferState.waitingReconnect,
    );
    expect(Directory(paused.tempPath).existsSync(), isTrue);

    sender.onSend = null;
    final resumedFrom = <int>[];
    receiver.onSend = (frame) {
      if (frame.type == WhisperFrameType.fileReady) {
        resumedFrom.add(frame.offset);
      }
      return true;
    };
    sender.reconnect();
    receiver.reconnect();
    await sender.engine.resumeRecoverableOutgoing();
    final received = await receiver.waitForState(
      transferId,
      FileTransferState.completed,
    );
    await sender.waitForState(transferId, FileTransferState.completed);

    expect(resumedFrom.single, greaterThan(0));
    expect(_snapshot(Directory(received.finalPath)), _snapshot(source));
    expect(received.skippedEntries ?? 0, 0);
    expect(receiver.rejections, isEmpty);
    expect(sender.rejections, isEmpty);
  });

  test('the sender never shows more than the receiver has confirmed', () async {
    _writeTree(source, sampleTree());
    connect();
    // One acknowledgement is held back for a while. By then everything in
    // the window has been sent, which is not what may be shown.
    var confirmed = 0;
    int? confirmedBeforeHold;
    int? shownDuringHold;
    receiver.beforeDeliver = (frame) async {
      if (frame.type != WhisperFrameType.fileAck &&
          frame.type != WhisperFrameType.fileReady) {
        return;
      }
      if (confirmedBeforeHold == null && frame.offset >= 2000 * _kib) {
        confirmedBeforeHold = confirmed;
        await Future<void>.delayed(const Duration(milliseconds: 600));
        shownDuringHold = sender.snapshots
            .where((item) => item.state == FileTransferState.transferring)
            .fold<int>(0, (most, item) => math.max(most, item.committedBytes));
      }
      confirmed = frame.offset;
    };

    await sender.engine.sendFolderTo('receiver', source.path);
    final transferId = _onlyTransferId(sender);
    await sender.waitForState(transferId, FileTransferState.completed);

    expect(confirmedBeforeHold, isNotNull);
    expect(shownDuringHold, lessThanOrEqualTo(confirmedBeforeHold!));
    final shown = <int>[
      for (final snapshot in sender.snapshots)
        if (snapshot.state == FileTransferState.transferring)
          snapshot.committedBytes,
    ];
    expect(shown, isNotEmpty);
    for (var index = 1; index < shown.length; index += 1) {
      expect(shown[index], greaterThanOrEqualTo(shown[index - 1]));
    }
  });

  test(
    'a receiver that falls silent for a while still gets the folder',
    () async {
      _writeTree(source, sampleTree());
      connect(ackTimeout: const Duration(milliseconds: 300));
      // As when one file takes long to write: nothing reaches the sender for
      // longer than it waits for progress, then everything picks up again.
      var held = false;
      receiver.beforeDeliver = (frame) async {
        if (held ||
            frame.type != WhisperFrameType.fileAck ||
            frame.offset < 2000 * _kib) {
          return;
        }
        held = true;
        await Future<void>.delayed(const Duration(milliseconds: 450));
      };

      await sender.engine.sendFolderTo('receiver', source.path);
      final transferId = _onlyTransferId(sender);
      final received = await receiver.waitForState(
        transferId,
        FileTransferState.completed,
      );
      await sender.waitForState(transferId, FileTransferState.completed);

      expect(held, isTrue);
      expect(_snapshot(Directory(received.finalPath)), _snapshot(source));
      expect(received.skippedEntries ?? 0, 0);
      // Nothing was sent twice: the receiver had it all along.
      final offsets = <int>[
        for (final frame in sender.sent)
          if (frame.type == WhisperFrameType.fileData) frame.offset,
      ];
      expect(offsets.toSet(), hasLength(offsets.length));
      expect(sender.unresponsiveVerdicts, 0);
      expect(receiver.rejections, isEmpty);
      expect(sender.rejections, isEmpty);
    },
  );

  group('a receiver still writing what it has', () {
    // The last frame is held back, so the receiver sits on data it has not
    // made durable yet for as long as the test wants: a long write.
    Future<String> sendWithLastFrameHeld(Duration hold) async {
      _writeTree(source, <String, List<int>>{
        'clip.bin': _pattern(1900 * _kib, 9),
      });
      sender.beforeDeliver = (frame) async {
        if (frame.type == WhisperFrameType.fileData &&
            frame.offset >= 1536 * _kib) {
          await Future<void>.delayed(hold);
        }
      };
      await sender.engine.sendFolderTo('receiver', source.path);
      return _onlyTransferId(sender);
    }

    test('keeps the sender waiting by saying so', () async {
      connect(
        ackTimeout: const Duration(milliseconds: 200),
        keepAliveInterval: const Duration(milliseconds: 60),
        checkpointInterval: const Duration(seconds: 30),
        ackIntervalSize: 4096 * _kib,
      );
      // Three timeouts in a row would have passed long before the hold ends.
      final transferId = await sendWithLastFrameHeld(
        const Duration(milliseconds: 1500),
      );
      final received = await receiver.waitForState(
        transferId,
        FileTransferState.completed,
      );
      await sender.waitForState(transferId, FileTransferState.completed);

      final repeated = <int>[
        for (final frame in receiver.sent)
          if (frame.type == WhisperFrameType.fileAck) frame.offset,
      ];
      expect(repeated.length, greaterThan(repeated.toSet().length));
      expect(_snapshot(Directory(received.finalPath)), _snapshot(source));
      expect(sender.unresponsiveVerdicts, 0);
      expect(receiver.rejections, isEmpty);
      expect(sender.rejections, isEmpty);
    });

    test('is given up on once that has gone on too long', () async {
      connect(
        ackTimeout: const Duration(milliseconds: 200),
        keepAliveInterval: const Duration(milliseconds: 60),
        checkpointInterval: const Duration(seconds: 30),
        ackIntervalSize: 4096 * _kib,
        quietLimit: const Duration(milliseconds: 400),
      );
      await sendWithLastFrameHeld(const Duration(milliseconds: 2500));
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (sender.unresponsiveVerdicts == 0 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(sender.unresponsiveVerdicts, 1);
      expect(receiver.rejections, isEmpty);
      expect(sender.rejections, isEmpty);
    });
  });

  test('cancelling on the receiving side removes what was staged', () async {
    _writeTree(source, sampleTree());
    connect();
    final held = Completer<void>();
    var dataFrames = 0;
    // Let two frames through and lose the rest, so the folder stays open.
    sender.onSend = (frame) {
      if (frame.type != WhisperFrameType.fileData) return true;
      dataFrames += 1;
      if (dataFrames == 2) held.complete();
      return dataFrames <= 2;
    };

    await sender.engine.sendFolderTo('receiver', source.path);
    final transferId = _onlyTransferId(sender);
    await held.future;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final staging = (await receiver.database.fetchFileTransfer(
      transferId,
    ))!.tempPath;
    await receiver.engine.cancelTransfer(transferId);

    await receiver.waitForState(transferId, FileTransferState.canceled);
    await sender.waitForState(transferId, FileTransferState.paused);
    expect(Directory(staging).existsSync(), isFalse);
    expect(
      Directory(p.join(receiver.downloads.path, 'Project Files')).existsSync(),
      isFalse,
    );
  });

  test('cancelling on the sending side clears both ends', () async {
    _writeTree(source, sampleTree());
    connect();
    final held = Completer<void>();
    var dataFrames = 0;
    sender.onSend = (frame) {
      if (frame.type != WhisperFrameType.fileData) return true;
      dataFrames += 1;
      if (dataFrames == 2) held.complete();
      return dataFrames <= 2;
    };

    await sender.engine.sendFolderTo('receiver', source.path);
    final transferId = _onlyTransferId(sender);
    await held.future;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final staging = (await receiver.database.fetchFileTransfer(
      transferId,
    ))!.tempPath;
    expect(Directory(staging).existsSync(), isTrue);
    await sender.engine.cancelTransfer(transferId);

    await sender.waitForState(transferId, FileTransferState.canceled);
    await receiver.waitForState(transferId, FileTransferState.canceled);
    final manifest = File(await sender.store.manifestPath(transferId));
    for (var attempt = 0; attempt < 200; attempt += 1) {
      if (!manifest.existsSync() && !Directory(staging).existsSync()) break;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(manifest.existsSync(), isFalse);
    expect(Directory(staging).existsSync(), isFalse);
    expect(_snapshot(source), isNotEmpty, reason: 'the original is untouched');
  });

  test('a peer from before folders turns the offer down cleanly', () async {
    _writeTree(source, <String, List<int>>{
      'a.txt': <int>[1],
    });
    connect();
    // An older receiver answers an offer it cannot read with this error and
    // keeps nothing; the offer itself is not delivered here.
    sender.onSend = (frame) => frame.type != WhisperFrameType.fileOffer;

    await sender.engine.sendFolderTo('receiver', source.path);
    final transferId = _onlyTransferId(sender);
    final offer = sender.messages.single;
    expect(
      jsonDecode(offer.content!)['checksumAlgorithm'],
      isNot('sha256'),
      reason: 'the name an older peer checks for must not match',
    );
    final control = FileTransferV3Control(
      action: FileTransferV3Action.error,
      transferId: transferId,
      durableOffset: 0,
      size: offer.size,
      failureReason: FileTransferFailureReason.invalidMetadata,
    );
    await sender.engine.handleFrame(
      TransferConnectionBinding(peerId: 'receiver', generation: 1),
      WhisperFrameV3(
        type: WhisperFrameType.fileError,
        transferId: transferId,
        offset: 0,
        sequence: 0,
        payload: Uint8List.fromList(utf8.encode(jsonEncode(control.toJson()))),
      ),
      requireCurrent: () {},
    );

    final failed = await sender.waitForState(
      transferId,
      FileTransferState.failed,
    );
    expect(failed.lastError, 'folder_unsupported');
    expect(sender.notices, <String>['folder_unsupported']);
  });

  group('free space is checked before anything is received', () {
    // 2,000 files of ten bytes: next to nothing in bytes, but each takes a
    // block of its own on disk.
    Map<String, List<int>> manyTinyFiles() => <String, List<int>>{
      for (var index = 0; index < 2000; index += 1)
        'd${index % 20}/f$index.txt': List<int>.filled(10, 0x61),
    };

    test('a folder that does not fit is turned down', () async {
      _writeTree(source, manyTinyFiles());
      // Room for the bytes and the reserve, not for 2,020 blocks as well.
      connect(receiverAvailableBytes: 36 * 1024 * _kib);

      await sender.engine.sendFolderTo('receiver', source.path);
      final transferId = _onlyTransferId(sender);
      final refused = await sender.waitForState(
        transferId,
        FileTransferState.failed,
      );
      final received = await receiver.waitForState(
        transferId,
        FileTransferState.failed,
      );

      expect(refused.lastError, 'storage');
      expect(received.lastError, 'storage');
      expect(
        sender.sent.where((frame) => frame.type == WhisperFrameType.fileData),
        isEmpty,
      );
      expect(Directory(received.tempPath).existsSync(), isFalse);
      expect(receiver.downloads.listSync(), isEmpty);
    });

    test('with room for it the same folder is received', () async {
      _writeTree(source, manyTinyFiles());
      connect(receiverAvailableBytes: 48 * 1024 * _kib);

      await sender.engine.sendFolderTo('receiver', source.path);
      final transferId = _onlyTransferId(sender);
      final received = await receiver.waitForState(
        transferId,
        FileTransferState.completed,
      );

      expect(_snapshot(Directory(received.finalPath)), _snapshot(source));
    });
  });

  test('a folder offer whose numbers do not add up is refused', () async {
    connect();
    final content = jsonEncode(
      FileTransferV3Metadata(
        checksumAlgorithm: fileTransferFolderChecksumAlgorithm,
        checksumValue: 'a' * 64,
        maxChunkSize: 512 * _kib,
        maxWindowSize: 4096 * _kib,
        folder: const FolderOfferSummary(
          manifestLength: 100,
          fileCount: 2,
          directoryCount: 0,
          totalBytes: 50,
        ),
      ).toJson(),
    );

    expect(
      () => FileTransferV3Metadata.parseOffer(content, size: 999),
      throwsA(isA<FileTransferV3MetadataException>()),
    );
    expect(
      FileTransferV3Metadata.parseOffer(
        content,
        size: 100 + 50 + 2 * folderTrailerLength,
      ).isFolder,
      isTrue,
    );
  });

  test('a manifest that fails validation fails the transfer', () async {
    _writeTree(source, <String, List<int>>{
      'a.txt': <int>[1, 2, 3],
    });
    connect();
    // The first frame starts with the manifest; one flipped byte in it no
    // longer matches the digest the offer announced.
    sender.onSend = (frame) {
      if (frame.type == WhisperFrameType.fileData && frame.offset == 0) {
        frame.payload[30] ^= 0xff;
      }
      return true;
    };

    await sender.engine.sendFolderTo('receiver', source.path);
    final transferId = _onlyTransferId(sender);
    final refused = await receiver.waitForState(
      transferId,
      FileTransferState.failed,
    );
    final failed = await sender.waitForState(
      transferId,
      FileTransferState.failed,
    );

    expect(refused.lastError, 'invalid_metadata');
    expect(failed.lastError, 'invalid_metadata');
    expect(
      Directory(p.join(receiver.downloads.path, 'Project Files')).existsSync(),
      isFalse,
    );
  });

  test('sending explains why a folder cannot go', () async {
    _writeTree(source, <String, List<int>>{
      for (var index = 0; index < 6; index += 1) 'f$index': <int>[index],
    });
    connect(
      scanFolder: (path) async => scanFolderForTransfer(path, maxEntries: 3),
    );

    expect(
      await sender.engine.sendFolderTo('receiver', source.path),
      FolderSendOutcome.tooManyEntries,
    );
    expect(
      await sender.engine.sendFolderTo(
        'receiver',
        p.join(temp.path, 'missing'),
      ),
      FolderSendOutcome.unreadable,
    );
    if (!Platform.isWindows) {
      final odd = Directory(p.join(temp.path, 'what?'))..createSync();
      expect(
        await sender.engine.sendFolderTo('receiver', odd.path),
        FolderSendOutcome.invalidName,
      );
    }
    sender.linked = false;
    expect(
      await sender.engine.sendFolderTo('receiver', source.path),
      FolderSendOutcome.notConnected,
    );
    expect(sender.messages, isEmpty);
    expect(await sender.database.fetchRecoverableFileTransfers(), isEmpty);
    expect(
      sender.storeDirectory.existsSync()
          ? sender.storeDirectory.listSync()
          : const <FileSystemEntity>[],
      isEmpty,
    );
  });

  test(
    'thousands of small files stay one transfer',
    () async {
      final random = math.Random(5);
      _writeTree(source, <String, List<int>>{
        for (var index = 0; index < 4000; index += 1)
          'd${index % 61}/f$index.dat': List<int>.generate(
            10 + random.nextInt(600),
            (_) => random.nextInt(256),
          ),
      });
      connect();

      await sender.engine.sendFolderTo('receiver', source.path);
      final transferId = _onlyTransferId(sender);
      final received = await receiver.waitForState(
        transferId,
        FileTransferState.completed,
        timeout: const Duration(minutes: 2),
      );
      await sender.waitForState(transferId, FileTransferState.completed);

      expect(_snapshot(Directory(received.finalPath)), _snapshot(source));
      // The whole tree fits in a handful of frames; nothing is per file.
      expect(
        sender.sent.where((frame) => frame.type == WhisperFrameType.fileData),
        hasLength(lessThan(12)),
      );
      expect(sender.sent.length + receiver.sent.length, lessThan(400));
      expect(receiver.messages, hasLength(1));
      expect(receiver.rejections, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
