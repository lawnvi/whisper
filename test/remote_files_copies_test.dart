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
}
