import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  test('the socket layer gates, checks trust and never blocks on prompts', () {
    final svr = File('lib/socket/svrmanager.dart').readAsStringSync();
    final handler = svr.substring(
      svr.indexOf('case MessageEnum.FileBrowseControl:'),
      svr.indexOf('case MessageEnum.AudioGroupControl:'),
    );
    expect(handler, contains('storedRemote?.auth == true'));
    expect(
      handler,
      contains('unawaited(\n                FileBrowseHost.shared'),
    );
    expect(svr, contains('capabilities.remoteFilesV1 == true'));
    expect(
      svr,
      contains('TransferPlacements.shared.onTransferUpdated(snapshot)'),
    );
    final policy = File('lib/socket/wire_input_policy.dart').readAsStringSync();
    expect(policy, contains('MessageEnum.FileBrowseControl => true'));
  });

  test('every device asks before its files are browsed', () {
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('FileBrowsePromptHost(child: content)'));
  });
}
