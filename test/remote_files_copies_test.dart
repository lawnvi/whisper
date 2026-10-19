import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/remote_files/fs_copies.dart';
import 'package:whisper/remote_files/fs_placement.dart';
import 'package:whisper/socket/file_transfer_v3.dart';

TransferSnapshot _snap(
  String id,
  FileTransferState state, {
  int size = 1000,
  int done = 0,
  String error = '',
  FileTransferDirection direction = FileTransferDirection.outgoing,
}) => TransferSnapshot(
  transferId: id,
  messageUuid: id,
  peerUid: 'phone',
  direction: direction,
  state: state,
  finalPath: '',
  tempPath: '',
  size: size,
  committedBytes: done,
  lastError: error,
  updatedAt: 0,
);

void main() {
  test('a paste is one copy, from asking to done', () {
    final updates = StreamController<TransferSnapshot>.broadcast(sync: true);
    final copies = FileCopies(updates: updates.stream, nowMs: () => 0);
    addTearDown(copies.dispose);
    final batch = copies.start(
      upload: true,
      peerId: 'phone',
      deviceName: 'OnePlus',
      folder: 'Download',
      names: ['a.txt', 'b.txt'],
      signature: 'sig',
    );
    // Shown at once, before the other device has answered.
    expect(batch.phase, FileCopyPhase.starting);
    expect(copies.copying('sig'), same(batch));
    copies.add(batch, 'a');
    copies.add(batch, 'b');
    copies.started(batch);
    updates.add(_snap('a', FileTransferState.transferring, done: 400));
    updates.add(_snap('b', FileTransferState.queued));
    expect(batch.phase, FileCopyPhase.running);
    expect(batch.fraction, closeTo(0.2, 1e-9));
    updates.add(_snap('a', FileTransferState.completed, done: 1000));
    updates.add(_snap('b', FileTransferState.waitingReconnect, done: 300));
    expect(batch.phase, FileCopyPhase.waiting);
    expect(batch.itemsDone, 1);
    updates.add(_snap('b', FileTransferState.completed, done: 1000));
    expect(batch.phase, FileCopyPhase.done);
    expect(batch.finished, isTrue);
    expect(copies.copying('sig'), isNull);
    // Updates for other transfers are not this copy's.
    updates.add(_snap('x', FileTransferState.failed));
    expect(batch.transfers.keys, ['a', 'b']);
  });

  test('a copy answered before its id was known does not stay preparing', () {
    final updates = StreamController<TransferSnapshot>.broadcast(sync: true);
    final copies = FileCopies(updates: updates.stream, nowMs: () => 0);
    addTearDown(copies.dispose);
    final batch = copies.start(
      upload: true,
      peerId: 'phone',
      deviceName: 'OnePlus',
      folder: 'Download',
      names: ['a.txt'],
      signature: 'sig',
    );
    // Turned down at once, before the offer's id reached the batch.
    updates.add(_snap('a', FileTransferState.failed, error: 'storage'));
    copies.add(batch, 'a');
    copies.started(batch);
    expect(batch.phase, FileCopyPhase.failed);
    expect(batch.lastError, 'storage');
  });

  test('a transfer the other device never starts counts as failed', () {
    var now = 0;
    final updates = StreamController<TransferSnapshot>.broadcast(sync: true);
    final copies = FileCopies(updates: updates.stream, nowMs: () => now);
    addTearDown(copies.dispose);
    final batch = copies.start(
      upload: false,
      peerId: 'phone',
      deviceName: 'OnePlus',
      folder: 'Download',
      names: ['a.txt'],
      signature: 'sig',
      again: () async => ['a2'],
    );
    copies.add(batch, 'a');
    copies.started(batch);
    expect(batch.phase, FileCopyPhase.starting);
    now = FileCopies.noShowAfter.inMilliseconds - 1;
    copies.tick();
    expect(batch.phase, FileCopyPhase.starting);
    now = FileCopies.noShowAfter.inMilliseconds;
    copies.tick();
    expect(batch.phase, FileCopyPhase.failed);
    expect(batch.lastError, FileCopies.noShowError);
    expect(batch.canResume, isTrue);
    // Showing up late still counts.
    updates.add(
      _snap(
        'a',
        FileTransferState.transferring,
        done: 10,
        direction: FileTransferDirection.incoming,
      ),
    );
    expect(batch.phase, FileCopyPhase.running);
  });

  test('the same paste again is the same copy, unless it failed', () {
    var now = 0;
    final updates = StreamController<TransferSnapshot>.broadcast(sync: true);
    final copies = FileCopies(updates: updates.stream, nowMs: () => now);
    addTearDown(copies.dispose);
    FileCopyBatch make(String id) {
      final batch = copies.start(
        upload: true,
        peerId: 'phone',
        deviceName: 'OnePlus',
        folder: 'Download',
        names: ['a.txt'],
        signature: 'sig',
      );
      copies.add(batch, id);
      copies.started(batch);
      return batch;
    }

    final first = make('a');
    // Under way: a second paste is this one.
    expect(copies.sameAs('sig'), same(first));
    expect(copies.sameAs('other'), isNull);
    updates.add(_snap('a', FileTransferState.completed, done: 1000));
    // Just done: still the same operation for a few seconds…
    now = 5000;
    expect(copies.sameAs('sig'), same(first));
    // …then a new copy can be made.
    now = 9000;
    expect(copies.sameAs('sig'), isNull);
    // One that failed can be tried again at once.
    final second = make('b');
    updates.add(_snap('b', FileTransferState.failed, error: 'x'));
    expect(second.phase, FileCopyPhase.failed);
    expect(copies.sameAs('sig'), isNull);
  });

  test('speed and time left follow the bytes of the last seconds', () {
    var now = 0;
    final updates = StreamController<TransferSnapshot>.broadcast(sync: true);
    final copies = FileCopies(updates: updates.stream, nowMs: () => now);
    addTearDown(copies.dispose);
    final batch = copies.start(
      upload: true,
      peerId: 'phone',
      deviceName: 'OnePlus',
      folder: 'Download',
      names: ['big.bin'],
      signature: 'sig',
    );
    copies.add(batch, 'a');
    copies.started(batch);
    for (var second = 0; second <= 4; second++) {
      now = second * 1000;
      updates.add(
        _snap(
          'a',
          FileTransferState.transferring,
          size: 100000000,
          done: second * 10000000,
        ),
      );
      copies.tick();
    }
    expect(batch.speed, closeTo(10000000, 1500000));
    expect(batch.remaining!.inSeconds, inInclusiveRange(5, 7));
    // Nothing arriving for a while: the speed falls away.
    for (var i = 0; i < 4; i++) {
      now += 1000;
      copies.tick();
    }
    expect(batch.speed, lessThan(3000000));
  });

  test('stopped copies carry on; the other device is asked again', () async {
    final updates = StreamController<TransferSnapshot>.broadcast(sync: true);
    final copies = FileCopies(updates: updates.stream, nowMs: () => 0);
    addTearDown(copies.dispose);
    final retried = <String>[];
    copies.retry = (id) async => retried.add(id);
    final up = copies.start(
      upload: true,
      peerId: 'phone',
      deviceName: 'OnePlus',
      folder: 'Download',
      names: ['a', 'b'],
      signature: 'up',
    );
    copies
      ..add(up, 'a')
      ..add(up, 'b')
      ..started(up);
    updates.add(_snap('a', FileTransferState.completed, done: 1000));
    updates.add(_snap('b', FileTransferState.paused, done: 500));
    expect(up.phase, FileCopyPhase.paused);
    expect(up.canResume, isTrue);
    await copies.resume(up);
    expect(retried, ['b']);

    var asked = 0;
    final down = copies.start(
      upload: false,
      peerId: 'phone',
      deviceName: 'OnePlus',
      folder: 'Downloads',
      names: ['c'],
      signature: 'down',
      again: () async {
        asked++;
        return ['c2'];
      },
    );
    copies
      ..add(down, 'c')
      ..started(down);
    updates.add(
      _snap(
        'c',
        FileTransferState.failed,
        direction: FileTransferDirection.incoming,
      ),
    );
    expect(down.phase, FileCopyPhase.failed);
    await copies.resume(down);
    expect(asked, 1);
    expect(down.transfers.keys, ['c2']);
    expect(down.phase, FileCopyPhase.starting);
  });

  test('a copy paused by a reconnect carries on by itself, once', () async {
    final placements = TransferPlacements();
    final resumed = <String>[];
    placements.resume = (id) async => resumed.add(id);
    placements.markQuiet('copy');
    await placements.onTransferUpdated(
      _snap('copy', FileTransferState.paused, done: 10),
    );
    await placements.onTransferUpdated(
      _snap('copy', FileTransferState.paused, done: 10),
    );
    // A chat transfer waits for its message to be tapped; one the other
    // side refused (an error) is not retried either.
    await placements.onTransferUpdated(
      _snap('chat', FileTransferState.paused, done: 10),
    );
    placements.markQuiet('refused');
    await placements.onTransferUpdated(
      _snap('refused', FileTransferState.paused, error: 'receiver_canceled'),
    );
    expect(resumed, ['copy']);
  });

  test('a copy the other side stopped is let go, not offered again', () async {
    // Stopped there, it is paused here; offered again, the other side,
    // having cancelled it, dropped the connection.
    final placements = TransferPlacements();
    final resumed = <String>[];
    final forgotten = <String>[];
    placements.resume = (id) async => resumed.add(id);
    placements.forgetRecord = (id) async => forgotten.add(id);
    placements.markQuiet('stopped');
    await placements.onTransferUpdated(
      _snap(
        'stopped',
        FileTransferState.paused,
        done: 10,
        error: fileTransferPeerCanceled,
      ),
    );
    expect(resumed, isEmpty);
    expect(forgotten, ['stopped']);
    expect(placements.isQuiet('stopped'), isFalse);
    // The engine says so when the receiver cancels one it was sending.
    final engine = File(
      'lib/socket/file_transfer_engine.dart',
    ).readAsStringSync();
    expect(engine, contains('? fileTransferPeerCanceled'));
  });

  test('a copy here is shown under the name it landed with', () {
    final updates = StreamController<TransferSnapshot>.broadcast(sync: true);
    final placed = StreamController<PlacedTransfer>.broadcast(sync: true);
    final copies = FileCopies(
      updates: updates.stream,
      placed: placed.stream,
      nowMs: () => 0,
    );
    addTearDown(copies.dispose);
    final batch = copies.start(
      upload: false,
      peerId: 'phone',
      deviceName: 'OnePlus',
      folder: 'Documents',
      names: ['a.txt', 'b.txt'],
      signature: 'sig',
    );
    // Nothing landed yet: the names asked for.
    expect(batch.landedNames, ['a.txt', 'b.txt']);
    // One placed before its id reached the batch, one after; "a.txt" was
    // taken in the folder.
    placed.add(
      const PlacedTransfer(transferId: 'a', path: '/home/Documents/a (1).txt'),
    );
    copies.add(batch, 'a');
    copies.add(batch, 'b');
    placed.add(
      const PlacedTransfer(transferId: 'b', path: '/home/Documents/b.txt'),
    );
    expect(batch.landedNames, ['a (1).txt', 'b.txt']);
  });

  test('copies show on an island on both layouts, with a list of them', () {
    String read(String path) => File(path).readAsStringSync();
    final desktop = read('lib/page/remote_files/files_desktop.dart');
    final phone = read('lib/page/remote_files/files_phone.dart');
    for (final page in [desktop, phone]) {
      expect(page, contains('FilesTransfersList('));
      // Phones and tablets show copies on the app's island and lend it
      // the page's "show all" and "show in Files".
      expect(page, contains('IslandCopyHooks.attach('));
    }
    // The in-window island is for desktops only: one island on a phone.
    expect(
      desktop,
      contains(
        'if (isDesktop())\n                  Positioned.fill(\n                    child: FilesCopyIsland(',
      ),
    );
    expect(phone, isNot(contains('FilesCopyIsland(')));
    // Not a quiet line in the corner any more.
    expect(desktop, isNot(contains('CopyProgressLabel')));
    expect(phone, isNot(contains('CopyProgressLabel')));
    // A second paste of the same thing points at the first.
    final actions = read('lib/page/remote_files/remote_files_page.dart');
    expect(actions, contains('controller.copyList.sameAs('));
    expect(actions, contains('showFilesConfirm('));
    expect(
      actions,
      isNot(
        contains(
          'CupertinoAlertDialog(\n          title: Text(l10n.remoteFilesDelete)',
        ),
      ),
    );
    // Copies carry on after a reconnect; the island's buttons reach the
    // transfer engine.
    final server = read('lib/socket/svrmanager.dart');
    expect(server, contains('..resume = retryTransfer'));
    expect(
      server,
      contains('..retry = retryTransfer\n        ..cancel = cancelTransfer;'),
    );
  });
}
