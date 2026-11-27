import 'dart:async';
import 'dart:io';

import 'package:clipboard_watcher/clipboard_watcher.dart';
import 'package:flutter/services.dart';
import 'package:whisper/clipboard/clipboard_ledger.dart';
import 'package:whisper/helper/clipboard_sync.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/remote_clipboard_transfer.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/socket/svrmanager.dart';

/// A keyboard and mouse sharing session the clipboard's files and images go
/// to.
typedef ClipboardSessionTarget = ({String peerId, String sessionId});

/// Sends what is copied on this device to the others.
///
/// Text goes to every connected device that has clipboard sync on. Files and
/// images go only to keyboard and mouse sharing sessions, where a paste on the
/// other side asks for them. What counts as already sent or as Whisper's own
/// write is decided by [ClipboardLedger] alone.
final class ClipboardSyncCoordinator implements ClipboardListener {
  ClipboardSyncCoordinator({
    ClipboardLedger? ledger,
    WsSvrManager? manager,
    LocalDatabase? database,
    Duration missedChangeInterval = const Duration(seconds: 1),
  }) : _ledger = ledger ?? ClipboardLedger.shared,
       _manager = manager ?? WsSvrManager(),
       _database = database ?? LocalDatabase(),
       _missedChangeInterval = missedChangeInterval;

  static final ClipboardSyncCoordinator shared = ClipboardSyncCoordinator();

  final ClipboardLedger _ledger;
  final WsSvrManager _manager;
  final LocalDatabase _database;
  final Duration _missedChangeInterval;
  final DesktopClipboardFileReader _fileReader =
      const DesktopClipboardFileReader();
  final DesktopClipboardImageReader _imageReader =
      const DesktopClipboardImageReader();
  final StreamController<void> _changes = StreamController<void>.broadcast();

  var _generation = 0;
  var _started = false;
  Timer? _missedChanges;
  Future<void> _serial = Future<void>.value();

  /// Every change the user made, sent or not: the clipboard history in the
  /// tray listens here.
  Stream<void> get changes => _changes.stream;

  /// Starts listening. On desktops the clipboard is also looked at every
  /// [missedChangeInterval], for a change notice that never came: Windows can
  /// lose its listener, and the token tells whether anything changed at all.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    final syncing = await LocalSetting().clipboardAutoSync();
    await _ledger.start(currentText: syncing ? await getClipboardText() : null);
    clipboardWatcher.addListener(this);
    if (isDesktop()) {
      _missedChanges = Timer.periodic(_missedChangeInterval, (_) {
        if (_manager.connectedPeerIds.isNotEmpty) onClipboardChanged();
      });
    }
  }

  Future<void> stop() async {
    _started = false;
    _missedChanges?.cancel();
    _missedChanges = null;
    clipboardWatcher.removeListener(this);
    _iosWatching = null;
    await clipboardWatcher.stop();
  }

  bool? _iosWatching;
  var _watcherGeneration = 0;

  /// Starts or stops the system's change notices. On iOS the plugin reads the
  /// pasteboard as soon as it starts, so there it runs only while automatic
  /// sync is on; call this again when that setting changes.
  Future<void> syncWatcher() async {
    if (!_started) return;
    if (!Platform.isIOS) {
      await clipboardWatcher.start();
      return;
    }
    final generation = ++_watcherGeneration;
    final enabled = await LocalSetting().clipboardAutoSync();
    if (!_started ||
        generation != _watcherGeneration ||
        enabled == _iosWatching) {
      return;
    }
    _iosWatching = enabled;
    try {
      if (enabled) {
        await clipboardWatcher.start();
      } else {
        await clipboardWatcher.stop();
      }
    } on Object {
      _iosWatching = null;
      rethrow;
    }
  }

  /// Text another device sent: put on this clipboard and not sent back.
  Future<void> applyRemoteText(String text) async {
    _ledger.noteSynced(text);
    try {
      await _ledger.ownWrite(
        () => Clipboard.setData(ClipboardData(text: text)),
      );
    } on Object catch (error) {
      logClipboardSync(ClipboardSyncStep.frameDropped, error: error);
      return;
    }
    _changes.add(null);
    // Files offered in a keyboard and mouse session are no longer what a
    // paste there should get.
    final sessions = isDesktop()
        ? _sessionTargets()
        : const <ClipboardSessionTarget>{};
    if (sessions.isEmpty || !await LocalSetting().clipboardAutoSync()) return;
    _manager.markLocalWorkspaceClipboard();
    await _clearSessions(sessions, notifyPeer: true);
  }

  @override
  void onClipboardChanged() {
    // Tokens are taken one at a time, in order; what follows runs alongside,
    // and a newer change makes an older one stop (the generation).
    final token = _serial.then((_) => _ledger.takeChange());
    _serial = token.then<void>((_) {}, onError: (Object _) {});
    unawaited(
      token.then((value) => value == null ? null : _handleChange()).catchError((
        Object error,
      ) {
        logClipboardSync(ClipboardSyncStep.skipped, error: error);
      }),
    );
  }

  Future<void> _handleChange() async {
    _changes.add(null);
    final generation = ++_generation;
    final syncing = await LocalSetting().clipboardAutoSync();
    if (isMobile() && !syncing) {
      logClipboardSync(
        ClipboardSyncStep.skipped,
        reason: ClipboardSyncReason.autoSyncOff,
      );
      return;
    }
    final sessions = isDesktop()
        ? _sessionTargets()
        : <ClipboardSessionTarget>{};
    final publishes = sessions.isNotEmpty && syncing;
    final fileDrafts = isDesktop()
        ? await _fileReader.readFileDrafts()
        : const <ClipboardFileDraft>[];
    traceRemoteClipboard(
      'clipboard_changed',
      count: fileDrafts.length,
      success: publishes,
    );
    if (!_isCurrent(generation)) return;
    if (fileDrafts.isNotEmpty) {
      _ledger.noteNotText();
      await _sendFiles(generation, sessions, fileDrafts, publishes: publishes);
      return;
    }
    final text = await readClipboardTextForSync(
      fileDraftsProvider: () async => const <ClipboardFileDraft>[],
    );
    if (!_isCurrent(generation)) return;
    if (publishes && (text == null || text.isEmpty)) {
      final image = await _imageReader.readImageBytes();
      if (!_isCurrent(generation)) return;
      if (image != null && image.isNotEmpty) {
        _ledger.noteNotText();
        await _sendImage(generation, sessions, image);
        return;
      }
    }
    if (text == null) {
      _ledger.noteNotText();
      logClipboardSync(
        ClipboardSyncStep.skipped,
        reason: ClipboardSyncReason.empty,
      );
      return;
    }
    await _sendText(generation, sessions, text, syncing: syncing);
  }

  bool _isCurrent(int generation) => generation == _generation;

  /// The keyboard and mouse sharing sessions that are live now, whichever
  /// side of them this device is on.
  Set<ClipboardSessionTarget> _sessionTargets() {
    final input = RemoteInputCoordinator.shared.state;
    final workspace = RemoteInputWorkspaceCoordinator.shared.snapshot;
    final targets = <ClipboardSessionTarget>{};
    final inSession =
        input.role == RemoteInputRuntimeRole.source ||
        input.role == RemoteInputRuntimeRole.sink;
    if (inSession && input.sessionId.isNotEmpty && input.peerId.isNotEmpty) {
      targets.add((peerId: input.peerId, sessionId: input.sessionId));
    }
    if (workspace.isControllerLive) {
      for (final target in workspace.targets.values) {
        if (target.isConnected) {
          targets.add((peerId: target.peerId, sessionId: target.sessionId));
        }
      }
    }
    return targets;
  }

  bool _sessionIsLive(ClipboardSessionTarget target) =>
      _sessionTargets().contains(target);

  Future<void> _sendFiles(
    int generation,
    Set<ClipboardSessionTarget> sessions,
    List<ClipboardFileDraft> drafts, {
    required bool publishes,
  }) async {
    final paths = drafts.map((draft) => draft.path).toList(growable: false);
    for (final target in sessions) {
      // A paste's files, copied again: they would only go back where they
      // came from.
      if (_manager.remoteClipboardOwnsPaths(
        sessionId: target.sessionId,
        paths: paths,
      )) {
        logClipboardSync(
          ClipboardSyncStep.skipped,
          reason: ClipboardSyncReason.sessionFiles,
        );
        return;
      }
    }
    logClipboardSync(
      ClipboardSyncStep.skipped,
      reason: ClipboardSyncReason.files,
      count: publishes ? sessions.length : 0,
    );
    if (!publishes) return;
    _manager.markLocalWorkspaceClipboard();
    await _clearSessions(sessions);
    if (!_isCurrent(generation)) return;
    final items = drafts
        .map(RemoteClipboardLocalItem.file)
        .toList(growable: false);
    for (final target in sessions) {
      await _publish(generation, target, items);
    }
  }

  Future<void> _sendImage(
    int generation,
    Set<ClipboardSessionTarget> sessions,
    Uint8List image,
  ) async {
    logClipboardSync(
      ClipboardSyncStep.skipped,
      reason: ClipboardSyncReason.image,
      count: sessions.length,
    );
    _manager.markLocalWorkspaceClipboard();
    await _clearSessions(sessions);
    if (!_isCurrent(generation)) return;
    final items = <RemoteClipboardLocalItem>[
      RemoteClipboardLocalItem.bytes('Clipboard Image.png', image),
    ];
    for (final target in sessions) {
      await _publish(generation, target, items);
    }
  }

  Future<void> _sendText(
    int generation,
    Set<ClipboardSessionTarget> sessions,
    String text, {
    required bool syncing,
  }) async {
    if (syncing && sessions.isNotEmpty) {
      // Files offered earlier in a session are no longer what a paste there
      // should get.
      _manager.markLocalWorkspaceClipboard();
      await _clearSessions(sessions, notifyPeer: true);
    }
    // Sent last time, or what another device sent: the others have it.
    if (_ledger.syncedText == text) {
      logClipboardSync(
        ClipboardSyncStep.skipped,
        reason: ClipboardSyncReason.unchanged,
      );
      return;
    }
    if (!syncing) {
      logClipboardSync(
        ClipboardSyncStep.skipped,
        reason: ClipboardSyncReason.autoSyncOff,
      );
      return;
    }
    if (!_isCurrent(generation)) return;
    final peerIds = await _textTargets();
    if (!_isCurrent(generation)) return;
    if (peerIds.isEmpty) {
      // Only a send counts: copied while nothing was connected, the same text
      // has to go out the next time.
      logClipboardSync(
        ClipboardSyncStep.skipped,
        reason: ClipboardSyncReason.noTarget,
        count: 0,
      );
      return;
    }
    var sent = 0;
    // Before the awaits: a second notice for this copy finds it sent.
    _ledger.noteSynced(text);
    for (final peerId in peerIds) {
      if (!_isCurrent(generation) || !_manager.isConnectedTo(peerId)) {
        continue;
      }
      if (await _manager.sendMessageTo(peerId, text, clipboard: true)) {
        sent += 1;
      }
    }
    logClipboardSync(
      sent > 0 ? ClipboardSyncStep.sent : ClipboardSyncStep.skipped,
      reason: sent > 0 ? null : ClipboardSyncReason.noTarget,
      count: sent,
    );
  }

  /// Every connected, trusted device that has clipboard sync on.
  Future<List<String>> _textTargets() async {
    final targets = <String>[];
    for (final peerId in _manager.connectedPeerIds.toList(growable: false)) {
      final device = await _database.fetchDevice(peerId);
      if (device == null ||
          !device.auth ||
          !device.clipboard ||
          device.identityPublicKey.isEmpty) {
        continue;
      }
      targets.add(peerId);
    }
    return targets;
  }

  Future<void> _clearSessions(
    Set<ClipboardSessionTarget> sessions, {
    bool notifyPeer = false,
  }) async {
    for (final target in sessions) {
      await _manager.clearRemoteClipboardSession(
        peerId: target.peerId,
        sessionId: target.sessionId,
        notifyPeer: notifyPeer,
      );
    }
  }

  Future<void> _publish(
    int generation,
    ClipboardSessionTarget target,
    List<RemoteClipboardLocalItem> items,
  ) async {
    // The widest limits: the engine applies the narrower ones of frames when
    // the files can't go as transfers.
    if (items.isEmpty ||
        items.length > remoteClipboardTransferMaxItems ||
        items.any((item) => item.size > remoteClipboardTransferMaxFileBytes) ||
        items.fold<int>(0, (sum, item) => sum + item.size) >
            remoteClipboardTransferMaxBatchBytes) {
      traceRemoteClipboard('publish_skipped', reason: 'settings_or_limits');
      return;
    }
    final device = await _database.fetchDevice(target.peerId);
    if (!_isCurrent(generation) ||
        !_sessionIsLive(target) ||
        device == null ||
        !device.auth ||
        !device.clipboard ||
        device.identityPublicKey.isEmpty ||
        !_manager.isConnectedTo(target.peerId)) {
      traceRemoteClipboard('publish_skipped', reason: 'peer_or_session');
      return;
    }
    final published = await _manager.publishRemoteClipboard(
      peerId: target.peerId,
      sessionId: target.sessionId,
      items: items,
    );
    traceRemoteClipboard('publish_done', success: published);
  }
}
