import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/remote_files/fs_client.dart';
import 'package:whisper/remote_files/fs_host.dart';
import 'package:whisper/remote_files/fs_host_files.dart';
import 'package:whisper/remote_files/fs_paths.dart';
import 'package:whisper/remote_files/fs_placement.dart';
import 'package:whisper/remote_files/fs_protocol.dart';
import 'package:whisper/remote_files/fs_share_policy.dart';
import 'package:whisper/remote_files/fs_shared_folders.dart';

/// Answers prompts with [decision] as soon as they appear.
class _AutoGate extends FileBrowseGate {
  _AutoGate(this.decision);

  FileBrowseDecision decision;
  int asked = 0;

  @override
  Future<FileBrowseDecision> ask(FileBrowseRequest request) async {
    asked++;
    return decision;
  }
}

/// Blocks `list` until [releaseList] completes, to verify that slow directory
/// listings do not stall concurrent mounted-folder `read` requests.
class _SlowListFiles extends FsHostFiles {
  _SlowListFiles({required super.resolver});

  final listStarted = Completer<void>();
  final releaseList = Completer<void>();

  @override
  Future<FsPage> list(
    String rootId,
    String relative, {
    int offset = 0,
    int limit = FsHostFiles.pageSize,
    bool showHidden = false,
  }) async {
    if (!listStarted.isCompleted) {
      listStarted.complete();
    }
    await releaseList.future;
    return super.list(
      rootId,
      relative,
      offset: offset,
      limit: limit,
      showHidden: showHidden,
    );
  }
}

void main() {
  late Directory sandbox;
  late FileBrowseHost host;
  late _AutoGate gate;
  final sentFiles = <(String, String)>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sandbox = await Directory.systemTemp.createTemp('whisper-rf-');
    await Directory(p.join(sandbox.path, 'Documents')).create();
    await File(p.join(sandbox.path, 'Documents', 'a.txt')).writeAsString('a');
    gate = _AutoGate(FileBrowseDecision.once);
    host = FileBrowseHost(
      files: FsHostFiles(
        resolver: FsPathResolver([
          FsRoot(
            id: 'home',
            directory: sandbox.path,
            shortcuts: const [FsShortcut(kind: 'documents', path: 'Documents')],
          ),
        ]),
      ),
      gate: gate,
    );
    sentFiles.clear();
    // Wire both ends together as if over the chat channel, through JSON.
    host.sender = (peerId, message) async {
      final copy = FileBrowseMessage.fromJson(
        jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
      );
      scheduleMicrotask(
        () => RemoteFilesClient.handle(copy, remotePeerId: 'host'),
      );
      return true;
    };
    host.sendFile = (peerId, path, id) async {
      sentFiles.add((path, id));
      return true;
    };
    RemoteFilesClient.localPeerId = (_) => 'client';
    RemoteFilesClient.sender = (peerId, message) async {
      final copy = FileBrowseMessage.fromJson(
        jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
      );
      scheduleMicrotask(
        () => host.handle(copy, remotePeerId: 'client', deviceName: 'Mac'),
      );
      return true;
    };
  });

  tearDown(() => sandbox.delete(recursive: true));

  test('messages round-trip and know their direction', () {
    const open = FileBrowseMessage(
      action: FileBrowseAction.open,
      sessionId: '5a4f1f0e-1c2b-4d3e-8f9a-0b1c2d3e4f50',
      clientPeerId: 'client',
      hostPeerId: 'host',
    );
    expect(open.isInitial, isTrue);
    expect(open.fromHost, isFalse);
    final reply = open.reply(FileBrowseAction.denied);
    expect(reply.fromHost, isTrue);
    expect(reply.isTerminal, isTrue);
    expect(FileBrowseMessage.allActions, contains('incoming'));
    expect(
      () => FileBrowseMessage.fromJson({
        'action': 'list',
        'sessionId': 's',
        'sourcePeerId': 'c',
        'sinkPeerId': 'h',
        'requestId': -1,
      }),
      throwsFormatException,
    );
  });

  test('browsing asks once, lists, creates and renames', () async {
    final client = RemoteFilesClient('host');
    final info = await client.open();
    expect(gate.asked, 1);
    expect(info.roots.single.id, 'home');
    expect(info.roots.single.shortcuts.single.kind, 'documents');
    final page = await client.list('home', 'Documents');
    expect(page.entries.single.name, 'a.txt');
    expect(await client.mkdir('home', 'Documents', 'New'), 'Documents/New');
    expect(
      await client.rename('home', 'Documents/New', 'Old'),
      'Documents/Old',
    );
    await expectLater(
      client.list('home', '../'),
      throwsA(
        isA<RemoteFsException>().having(
          (e) => e.reason,
          'reason',
          FileBrowseError.notAllowed,
        ),
      ),
    );
    await client.close();
    // A closed session answers nothing any more.
    final stale = RemoteFilesClient('host', sessionId: client.sessionId);
    await expectLater(
      stale.list('home', ''),
      throwsA(isA<RemoteFsException>()),
    );
  });

  test('"always allow" skips the question next time; deny ends it', () async {
    gate.decision = FileBrowseDecision.always;
    await RemoteFilesClient('host').open();
    await RemoteFilesClient('host').open();
    expect(gate.asked, 1);
    await host.permissions.setAlways('client', false);
    gate.decision = FileBrowseDecision.deny;
    await expectLater(
      RemoteFilesClient('host').open(),
      throwsA(
        isA<RemoteFsException>().having((e) => e.reason, 'reason', 'denied'),
      ),
    );
  });

  test('copies go out as transfers and land in the chosen folder', () async {
    final client = RemoteFilesClient('host');
    await client.open();
    final local = await Directory(p.join(sandbox.path, 'local')).create();
    final ids = await client.fetch([
      (root: 'home', path: 'Documents/a.txt'),
    ], local.path);
    expect(ids, hasLength(1));
    expect(sentFiles.single.$2, ids.single);
    expect(sentFiles.single.$1, endsWith('a.txt'));
    expect(TransferPlacements.shared.isExpected(ids.single), isTrue);

    // Upload: the host learns where the next transfer goes.
    final uploadIds = <String>[];
    RemoteFilesClient.sendFile = (peerId, path, id) async {
      uploadIds.add(id);
      return true;
    };
    final source = File(p.join(local.path, 'up.txt'))..writeAsStringSync('u');
    await client.upload([source.path], 'home', 'Documents');
    expect(TransferPlacements.shared.isExpected(uploadIds.single), isTrue);
  });

  test('a completed copy moves into its folder under a free name', () async {
    final placements = TransferPlacements();
    final downloads = await Directory(p.join(sandbox.path, 'dl')).create();
    final target = await Directory(p.join(sandbox.path, 'target')).create();
    await File(p.join(target.path, 'a.txt')).writeAsString('old');
    final arrived = File(p.join(downloads.path, 'a.txt'))
      ..writeAsStringSync('new');
    final relocated = <String>[];
    placements.relocateRecord = (id, from, to) async => relocated.add(to);
    placements.expect('t1', target.path);
    await placements.onTransferUpdated(
      TransferSnapshot(
        transferId: 't1',
        messageUuid: 't1',
        peerUid: 'host',
        direction: FileTransferDirection.incoming,
        state: FileTransferState.completed,
        finalPath: arrived.path,
        tempPath: '',
        size: 3,
        committedBytes: 3,
        lastError: '',
        updatedAt: 0,
      ),
    );
    expect(relocated.single, p.join(target.path, 'a 2.txt'));
    expect(File(relocated.single).readAsStringSync(), 'new');
    expect(arrived.existsSync(), isFalse);
    expect(placements.isExpected('t1'), isFalse);
  });

  test('file-manager copies stay out of the conversation', () async {
    TransferSnapshot snapshot(
      String id,
      FileTransferDirection direction,
      FileTransferState state,
    ) => TransferSnapshot(
      transferId: id,
      messageUuid: id,
      peerUid: 'peer',
      direction: direction,
      state: state,
      finalPath: '',
      tempPath: '',
      size: 1,
      committedBytes: 1,
      lastError: '',
      updatedAt: 0,
    );
    final placements = TransferPlacements();
    final forgotten = <String>[];
    placements.forgetRecord = (id) async => forgotten.add(id);
    placements.markQuiet('sent');
    placements.expect('fetched', sandbox.path);
    expect(placements.isQuiet('sent'), isTrue);
    expect(placements.isQuiet('fetched'), isTrue);
    expect(placements.isQuiet('chat'), isFalse);

    // Done: the message goes. Failed: it shows, to be retried there.
    await placements.onTransferUpdated(
      snapshot(
        'sent',
        FileTransferDirection.outgoing,
        FileTransferState.completed,
      ),
    );
    await placements.onTransferUpdated(
      snapshot(
        'fetched',
        FileTransferDirection.incoming,
        FileTransferState.failed,
      ),
    );
    expect(forgotten, ['sent']);
    expect(placements.isQuiet('sent'), isFalse);
    expect(placements.isQuiet('fetched'), isFalse);
    final conversation = File('lib/page/conversation.dart').readAsStringSync();
    expect(
      conversation,
      contains('TransferPlacements.shared.isQuiet(messageData.uuid)'),
    );
  });

  test('a computer shares whole disks less the system\'s folders and the '
      'ones left out', () async {
    final disk = await sandbox.resolveSymbolicLinks();
    final homeDir = p.join(disk, 'Users', 'me');
    for (final path in [
      'Users/me/Documents/a.txt',
      'Users/me/Music/song.mp3',
      'Users/me/Private/p.txt',
      'Users/me/Projects/x.txt',
      'Users/other/o.txt',
      'usr/bin/sh',
    ]) {
      final file = File(p.join(disk, path));
      await file.parent.create(recursive: true);
      await file.writeAsString(path);
    }
    final data = await Directory.systemTemp.createTemp('whisper-rf-data-');
    addTearDown(() => data.delete(recursive: true));
    await File(p.join(data.path, 'b.txt')).writeAsString('b');
    final dataDisk = FsRoot(
      id: 'vol:Data',
      directory: await data.resolveSymbolicLinks(),
      kind: FsRootKind.volume,
      label: 'Data',
    );
    final systemDisk = FsRoot(id: 'system', directory: disk, label: 'Disk');
    final homeRoot = FsRoot(
      id: 'home',
      directory: homeDir,
      shortcuts: const [
        FsShortcut(kind: 'documents', path: 'Documents'),
        FsShortcut(kind: 'music', path: 'Music'),
      ],
    );
    final folders = FsSharedFolders(
      protectedAreas: () async => FsProtectedAreas(home: homeDir),
      defaultRoots: () => [homeRoot],
      commonFolders: () async => const [],
      systemDisk: () async => systemDisk,
      // A partition mounted in the home folder, switched off (Linux).
      disks: () async => [
        dataDisk,
        FsRoot(
          id: 'vol:Projects',
          directory: p.join(homeDir, 'Projects'),
          kind: FsRootKind.volume,
        ),
      ],
    );
    final sender = host.sender;
    host = FileBrowseHost(
      files: FsHostFiles(sharing: folders),
      gate: gate,
    )..sender = sender;
    var client = RemoteFilesClient('host');
    // A new session: an open one keeps the roots it was given.
    Future<RemoteFsInfo> reopen() async {
      await client.close();
      client = RemoteFilesClient('host');
      return client.open();
    }

    Future<List<String>> names(String root, String path) async => [
      for (final entry in (await client.list(root, path)).entries) entry.name,
    ];
    Matcher refused = throwsA(
      isA<RemoteFsException>().having(
        (e) => e.reason,
        'reason',
        FileBrowseError.notAllowed,
      ),
    );

    // The system disk at first, as its home folder alone: not the drive as
    // well (the same files twice), never the system's folders or other
    // users', nor a disk in it that is switched off.
    var info = await client.open();
    expect([for (final root in info.roots) root.id], ['home']);
    expect(await names('home', ''), ['Documents', 'Music', 'Private']);
    await expectLater(client.read('home', 'Projects/x.txt', 0, 1), refused);
    final policy = folders.policy;
    expect(
      policy.allows(p.join(disk, 'usr', 'bin', 'sh'), FsUse.read),
      isFalse,
    );
    expect(policy.allows(p.join(disk, 'Users', 'other'), FsUse.read), isFalse);

    // Left out: gone with all in it, from the next request on.
    final private = p.join(homeDir, 'Private');
    expect(await folders.exclude(private), FsExcluded.added);
    expect(await names('home', ''), ['Documents', 'Music']);
    await expectLater(client.list('home', 'Private'), refused);
    await expectLater(client.read('home', 'Private/p.txt', 0, 1), refused);
    // Already not shared: in a folder left out, or the system's.
    expect(await folders.exclude(p.join(private, 'sub')), FsExcluded.already);
    expect(await folders.exclude(p.join(disk, 'usr')), FsExcluded.already);
    // A folder holding ones left out takes them in.
    final music = p.join(homeDir, 'Music');
    expect(await folders.exclude(p.join(music, 'Live')), FsExcluded.added);
    expect(await folders.exclude(music), FsExcluded.added);
    expect(folders.excluded, [private, music]);
    info = await reopen();
    expect(info.roots.single.shortcuts.single.kind, 'documents');
    await folders.include(music);
    expect(await names('home', ''), ['Documents', 'Music']);

    // Another disk, once switched on; then the system disk off.
    await folders.shareDisk(dataDisk, true, system: false);
    info = await reopen();
    expect([for (final root in info.roots) root.id], ['home', 'vol:Data']);
    expect(await names('vol:Data', ''), ['b.txt']);
    await folders.shareDisk(systemDisk, false, system: true);
    await expectLater(client.list('home', ''), refused);
    await client.close();

    // Leaving out a whole disk switches it off.
    expect(await folders.exclude(data.path), FsExcluded.disk);
    expect(folders.sharedDisks, isEmpty);
  });

  test('F21: placements bind to peer, clear on disconnect/revocation, and '
      'browseWrite serializes with control checks', () async {
    final placements = TransferPlacements();
    final hostReplies = <FileBrowseMessage>[];
    final testHost =
        FileBrowseHost(
            files: FsHostFiles(
              resolver: FsPathResolver([
                FsRoot(id: 'home', directory: sandbox.path),
              ]),
            ),
            gate: _AutoGate(FileBrowseDecision.once),
            placements: placements,
          )
          ..sender = (peerId, msg) async {
            hostReplies.add(msg);
            return true;
          };

    const sid = '5a4f1f0e-1c2b-4d3e-8f9a-0b1c2d3e4f51';
    Future<void> sendControl(
      FileBrowseAction action, [
      Map<String, Object?> payload = const {},
      int requestId = 1,
    ]) => testHost.handle(
      FileBrowseMessage(
        action: action,
        sessionId: sid,
        clientPeerId: 'peer-a',
        hostPeerId: 'host',
        requestId: requestId,
        payload: payload,
      ),
      remotePeerId: 'peer-a',
      deviceName: 'Peer A',
    );

    await sendControl(FileBrowseAction.open);
    await sendControl(FileBrowseAction.incoming, {
      'transferId': 't-bind',
      'root': 'home',
      'folder': 'Documents',
    }, 2);
    expect(placements.isExpected('t-bind'), isTrue);

    // Another peer sending the same transferId must not place into peer-a's
    // target folder.
    final downloads = await Directory(p.join(sandbox.path, 'dl')).create();
    final foreign = File(p.join(downloads.path, 'evil.txt'))
      ..writeAsStringSync('x');
    await placements.onTransferUpdated(
      TransferSnapshot(
        transferId: 't-bind',
        messageUuid: 't-bind',
        peerUid: 'peer-b',
        direction: FileTransferDirection.incoming,
        state: FileTransferState.completed,
        finalPath: foreign.path,
        tempPath: '',
        size: 1,
        committedBytes: 1,
        lastError: '',
        updatedAt: 0,
      ),
    );
    expect(foreign.existsSync(), isTrue);
    expect(placements.isExpected('t-bind'), isTrue);

    // Revoking write permission clears host-side incoming placements while
    // sparing a local fetch placement from the same peer.
    placements.expect('t-local-fetch', downloads.path, peerId: 'peer-a');
    await testHost.setReadOnly('peer-a', true);
    expect(placements.isExpected('t-bind'), isFalse);
    expect(placements.isExpected('t-local-fetch'), isTrue);

    // Re-enabling write, registering another incoming placement, then
    // disconnecting clears it too.
    await testHost.setReadOnly('peer-a', false);
    await sendControl(FileBrowseAction.incoming, {
      'transferId': 't-disc',
      'root': 'home',
      'folder': 'Documents',
    }, 3);
    expect(placements.isExpected('t-disc'), isTrue);
    testHost.closePeer('peer-a');
    expect(placements.isExpected('t-disc'), isFalse);

    // Serial path: writeOpen -> browseWrite -> writeClose (all dispatched
    // back-to-back without awaiting) execute in strict arrival order.
    await sendControl(FileBrowseAction.open);
    hostReplies.clear();
    final openFuture = sendControl(FileBrowseAction.writeOpen, {
      'root': 'home',
      'path': 'Documents/a.txt',
      'truncate': true,
    }, 10);
    await openFuture;
    final uploadId = hostReplies.last.payload['upload'] as String;
    hostReplies.clear();

    final w1 = testHost.handleWrite(
      remotePeerId: 'peer-a',
      transferId: '$sid/$uploadId',
      requestId: 11,
      offset: 0,
      data: Uint8List.fromList(utf8.encode('hello ')),
    );
    final w2 = testHost.handleWrite(
      remotePeerId: 'peer-a',
      transferId: '$sid/$uploadId',
      requestId: 12,
      offset: 6,
      data: Uint8List.fromList(utf8.encode('world')),
    );
    final closeFuture = sendControl(FileBrowseAction.writeClose, {
      'upload': uploadId,
      'commit': true,
    }, 13);
    await Future.wait([w1, w2, closeFuture]);
    expect(hostReplies.map((m) => (m.requestId, m.action)).toList(), [
      (11, FileBrowseAction.result),
      (12, FileBrowseAction.result),
      (13, FileBrowseAction.result),
    ]);
    expect(
      File(p.join(sandbox.path, 'Documents', 'a.txt')).readAsStringSync(),
      'hello world',
    );
  });

  // Regression: serializing every FileBrowseHost request per peer blocked
  // mounted-folder `read` calls behind a slow `list`/`thumb`/`fetch`, which
  // could hit the OS mount timeout (e.g. macOS NFS deadtimeout=10).
  test(
    'a slow list does not block concurrent reads from the same peer',
    () async {
      final slowFiles = _SlowListFiles(
        resolver: FsPathResolver([FsRoot(id: 'home', directory: sandbox.path)]),
      );
      final readCompleted = Completer<Uint8List>();
      final replies = <FileBrowseMessage>[];
      final testHost =
          FileBrowseHost(
              files: slowFiles,
              gate: _AutoGate(FileBrowseDecision.once),
              placements: TransferPlacements(),
            )
            ..sender = (peerId, msg) async {
              replies.add(msg);
              return true;
            }
            ..sendData = (peerId, sessionId, requestId, offset, data) async {
              if (!readCompleted.isCompleted) {
                readCompleted.complete(data);
              }
              return true;
            };

      const sid = '5a4f1f0e-1c2b-4d3e-8f9a-0b1c2d3e4f52';
      await testHost.handle(
        const FileBrowseMessage(
          action: FileBrowseAction.open,
          sessionId: sid,
          clientPeerId: 'peer-a',
          hostPeerId: 'host',
        ),
        remotePeerId: 'peer-a',
        deviceName: 'Peer A',
      );

      final listFuture = testHost.handle(
        const FileBrowseMessage(
          action: FileBrowseAction.list,
          sessionId: sid,
          clientPeerId: 'peer-a',
          hostPeerId: 'host',
          requestId: 1,
          payload: {'root': 'home', 'path': 'Documents'},
        ),
        remotePeerId: 'peer-a',
        deviceName: 'Peer A',
      );
      await slowFiles.listStarted.future;

      // Issue a read from the exact same peer and session while `list` is stuck.
      await testHost
          .handle(
            const FileBrowseMessage(
              action: FileBrowseAction.read,
              sessionId: sid,
              clientPeerId: 'peer-a',
              hostPeerId: 'host',
              requestId: 2,
              payload: {
                'root': 'home',
                'path': 'Documents/a.txt',
                'offset': 0,
                'length': 1,
              },
            ),
            remotePeerId: 'peer-a',
            deviceName: 'Peer A',
          )
          .timeout(const Duration(seconds: 2));
      final data = await readCompleted.future.timeout(
        const Duration(seconds: 2),
      );
      expect(utf8.decode(data), 'a');

      slowFiles.releaseList.complete();
      await listFuture;
      expect(replies.any((m) => m.requestId == 1), isTrue);
    },
  );

  test(
    'stat returns single entry metadata and enforces path boundaries',
    () async {
      final client = RemoteFilesClient('host');
      await client.open();

      final fileEntry = await client.stat('home', 'Documents/a.txt');
      expect(fileEntry.name, 'a.txt');
      expect(fileEntry.isDir, isFalse);
      expect(fileEntry.size, 1);

      final dirEntry = await client.stat('home', 'Documents');
      expect(dirEntry.name, 'Documents');
      expect(dirEntry.isDir, isTrue);

      await expectLater(
        client.stat('home', 'Documents/missing.txt'),
        throwsA(
          isA<RemoteFsException>().having(
            (e) => e.reason,
            'reason',
            FileBrowseError.notFound,
          ),
        ),
      );
      await expectLater(
        client.stat('home', '../outside'),
        throwsA(
          isA<RemoteFsException>().having(
            (e) => e.reason,
            'reason',
            FileBrowseError.notAllowed,
          ),
        ),
      );
      await client.close();
    },
  );
}
