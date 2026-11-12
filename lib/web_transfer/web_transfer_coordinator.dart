import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:whisper/helper/device_form_factor.dart';
import 'package:whisper/helper/file.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/share_links/share_link_store.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/theme/whisper_device_art.dart';

import 'web_transfer_protocol.dart';
import 'web_transfer_records.dart';
import 'web_transfer_routes.dart';
import 'web_transfer_session.dart';
import 'web_transfer_uploads.dart';
import 'web_transfer_visitor.dart';

/// What [AppLog] hears about web transfer: events and reasons, never who.
enum WebTransferEvent {
  opened,
  closed,
  asked,
  allowed,
  declined,
  ended,
  failed,
}

/// A browser asking to connect, for the island.
class WebVisitorRequest {
  const WebVisitorRequest({
    required this.uid,
    required this.name,
    required this.platform,
    required this.tablet,
    required this.code,
  });

  final String uid;
  final String name;
  final String platform;
  final bool tablet;
  final String code;
}

/// Web transfer on this device: whether it takes new visitors, every visit
/// and what each one sends and receives. See docs/internals/web-transfer.md.
///
/// A visitor is a row in the device table, and what it sends are ordinary
/// messages and transfers ([WebTransferRecords]): they reach the
/// conversation, the device list and the island the way a Whisper device's
/// do.
class WebTransferCoordinator extends ChangeNotifier {
  WebTransferCoordinator({
    LocalDatabase? database,
    ShareLinkStore? links,
    Future<DeviceData> Function()? self,
    Future<String> Function()? selfName,
    Future<Directory> Function()? receiveDirectory,
    Future<String> Function()? loadPage,
    void Function(MessageData message)? onMessage,
    void Function(TransferSnapshot snapshot)? onTransfer,
    this.answerTimeout = const Duration(seconds: 60),
    this.awayTimeout = const Duration(minutes: 10),
    this.maxSessions = 4,
    this.maxPending = 3,
  }) : _links = links,
       _self = self ?? (() => LocalSetting().instance()),
       _selfName = selfName ?? (() => LocalSetting().deviceDisplayName()),
       _receiveDirectory = receiveDirectory ?? downloadDir {
    records = WebTransferRecords(
      database: () => database ?? LocalDatabase(),
      onMessage: onMessage ?? WsSvrManager().dispatchMessage,
      onTransfer: onTransfer ?? WsSvrManager().dispatchTransfer,
    );
    routes = WebTransferRoutes(this, loadPage: loadPage);
  }

  static final shared = WebTransferCoordinator();

  final Duration answerTimeout;
  final Duration awayTimeout;

  /// Visits that have not ended, waiting ones included.
  final int maxSessions;

  /// Waiting for an answer, in all (one per address).
  final int maxPending;

  final ShareLinkStore? _links;
  final Future<DeviceData> Function() _self;
  final Future<String> Function() _selfName;
  final Future<Directory> Function() _receiveDirectory;

  late final WebTransferRecords records;
  late final WebTransferRoutes routes;

  ShareLinkStore get links => _links ?? ShareLinkStore.shared;

  final _sessions = <String, WebSession>{};
  bool _hosting = false;
  bool _installed = false;
  bool _swept = false;

  /// The panel is open: new visitors can ask.
  bool get hosting => _hosting;

  /// The address to give, `http://<address>:<port>/`, or null while there
  /// is no network or the server is not up.
  String? urlFor([String? address]) {
    final host = address ?? links.address;
    if (host == null || !links.serverState.isRunning) {
      return null;
    }
    return 'http://$host:${links.port}/';
  }

  /// Visitors whose page is connected right now.
  Set<String> get onlineUids => {
    for (final session in _sessions.values)
      if (session.live) session.uid,
  };

  bool isOnline(String uid) => _sessions[uid]?.live ?? false;

  /// The browser [uid]'s page said it runs in, while it is here: a name such
  /// as Safari, or null.
  String? browserOf(String uid) => switch (_sessions[uid]?.hello.browser) {
    'safari' => 'Safari',
    'chrome' => 'Chrome',
    'firefox' => 'Firefox',
    'edge' => 'Edge',
    'opera' => 'Opera',
    'samsung' => 'Samsung Internet',
    'miui' => 'Xiaomi Browser',
    'huawei' => 'Huawei Browser',
    'wechat' => 'WeChat',
    _ => null,
  };

  /// Messages and files can go to [uid]: it was allowed and has not ended,
  /// though its page may be away for a moment.
  bool canSend(String uid) => _sessions[uid]?.allowed ?? false;

  List<WebVisitorRequest> get requests => [
    for (final session in _sessions.values)
      if (session.phase == WebSessionPhase.pending)
        WebVisitorRequest(
          uid: session.uid,
          name: webVisitorName(session.hello),
          platform: webVisitorPlatform(session.hello),
          tablet: session.hello.kind == 'tablet',
          code: session.code,
        ),
  ];

  /// The panel opened: starts the server and takes requests.
  Future<void> open() async {
    install();
    if (!_swept) {
      _swept = true;
      try {
        await records.sweep();
      } on Object catch (error) {
        _log(WebTransferEvent.failed, error: error);
      }
    }
    if (!_hosting) {
      _hosting = true;
      _log(WebTransferEvent.opened);
      notifyListeners();
    }
    await links.hold(true);
  }

  /// The panel closed. Visitors already in stay; nobody new can ask.
  Future<void> close() async {
    if (_hosting) {
      _hosting = false;
      _log(WebTransferEvent.closed);
      notifyListeners();
    }
    await _releaseIfIdle();
  }

  /// This device's answer to [uid]'s request.
  Future<void> answer(String uid, bool allow) async {
    final session = _sessions[uid];
    if (session == null || session.phase != WebSessionPhase.pending) {
      return;
    }
    session.cancelDeadline();
    if (!allow) {
      links.server.limiter.fail(session.client);
      _drop(session, WebFrame.declined);
      _log(WebTransferEvent.declined);
      return;
    }
    if (session.socket == null) {
      session
        ..phase = WebSessionPhase.away
        ..deadline = Timer(awayTimeout, () => _end(session, 'expired'));
    } else {
      session.phase = WebSessionPhase.online;
    }
    await records.saveVisitor(session, online: session.live);
    _log(WebTransferEvent.allowed);
    notifyListeners();
    await _welcome(session);
  }

  /// This device disconnects [uid]. Its records stay.
  Future<void> end(String uid) async {
    final session = _sessions[uid];
    if (session != null) {
      await _end(session, 'host');
    }
  }

  /// The app is quitting: every visit ends.
  Future<void> shutdown() async {
    _hosting = false;
    for (final session in _sessions.values.toList()) {
      await _end(session, 'host');
    }
    await _releaseIfIdle();
  }

  Future<bool> sendText(String uid, String text) async {
    final session = _sessions[uid];
    if (session == null || !session.allowed || text.isEmpty) {
      return false;
    }
    final self = await _self();
    final message = await records.addText(
      sender: self.uid,
      receiver: uid,
      text: text,
      uuid: const Uuid().v4(),
      acked: session.live,
    );
    if (message != null) {
      session.send(WebFrame.text, {
        'id': message.uuid,
        'from': 'host',
        'body': text,
        'time': message.timestamp * 1000,
      });
    }
    return message != null;
  }

  /// Offers a file to [uid]; the page downloads it when its user wants. A
  /// [draft] (a screenshot, an image from the clipboard) lives in a
  /// temporary folder and is kept where received files go first, so it is
  /// still there when they do.
  Future<bool> sendFile(
    String uid,
    String path, {
    String? name,
    int? size,
    bool draft = false,
  }) async {
    final session = _sessions[uid];
    if (session == null || !session.allowed || path.isEmpty) {
      return false;
    }
    var source = path;
    if (!source.startsWith('content://')) {
      if (!await File(source).exists()) {
        return false;
      }
      if (draft) {
        source = await _keep(source);
      }
    }
    final self = await _self();
    final message = await records.addOutgoingFile(
      sender: self.uid,
      receiver: uid,
      path: source,
      name: name ?? p.basename(source),
      size: size ?? await File(source).length(),
      uuid: const Uuid().v4(),
    );
    session.send(
      WebFrame.file,
      WebTransferRecords.fileFields(message, from: 'host'),
    );
    return true;
  }

  /// The file card's cancel, for a file a visitor is sending here or one
  /// this device sent.
  Future<void> cancel(String transferId) async {
    for (final session in _sessions.values) {
      final upload = session.uploads[transferId];
      if (upload != null) {
        session.send(WebFrame.state, {
          'id': transferId,
          'state': WebUploadState.cancelled,
        });
        await _failUpload(session, upload, FileTransferState.canceled);
        return;
      }
    }
    await records.update(transferId, state: FileTransferState.canceled);
  }

  // The page's side, through [routes].

  /// A page connected its WebSocket from [client].
  void accept(WebSocket socket, String client) {
    socket.pingInterval = webPingInterval;
    WebSession? session;
    var queue = Future<void>.value();
    final helloDeadline = Timer(const Duration(seconds: 10), () {
      if (session == null) {
        unawaited(socket.close(WebSocketStatus.policyViolation));
      }
    });
    socket.listen(
      (data) {
        final frame = decodeWebFrame(data);
        if (frame == null) {
          if (data is! String || data.length > webMaxFrameBytes) {
            unawaited(socket.close(WebSocketStatus.messageTooBig));
          }
          return;
        }
        // One frame at a time, in order: a text sent right after hello must
        // not overtake it.
        queue = queue.then((_) async {
          try {
            final current = session;
            if (current != null) {
              await _onFrame(current, socket, frame);
              return;
            }
            final hello = WebHello.parse(frame);
            if (hello == null) {
              await socket.close(WebSocketStatus.policyViolation);
              return;
            }
            helloDeadline.cancel();
            session = await _hello(socket, client, hello);
          } on Object catch (error) {
            _log(WebTransferEvent.failed, error: error);
          }
        });
      },
      onDone: () {
        helloDeadline.cancel();
        queue = queue.then((_) {
          final current = session;
          if (current != null && identical(current.socket, socket)) {
            _socketGone(current);
          }
        });
      },
      onError: (Object _) {},
      cancelOnError: true,
    );
  }

  /// The visit a cookie belongs to, while it is allowed.
  WebSession? sessionFor(String? token) {
    if (token == null || token.isEmpty) {
      return null;
    }
    for (final session in _sessions.values) {
      if (session.token == token && session.allowed) {
        return session;
      }
    }
    return null;
  }

  /// How the page draws this device.
  Future<Map<String, String>> hostLooks() async {
    final self = await _self();
    final name = await _selfName();
    final kind = deviceKindFor(
      self.platform,
      name: name,
      tablet: DeviceFormFactors.shared.localIsTablet,
      formFactor: DeviceFormFactors.shared.local,
    ).name;
    final looks = webHostLooks(self.platform, kind);
    return {'name': name, 'os': looks.os, 'kind': looks.kind};
  }

  /// A `PUT` of [upload] ended, whole or not.
  Future<void> chunkDone(WebSession session, WebUpload upload) async {
    if (!upload.complete) {
      await records.update(upload.transferId, committed: upload.committed);
      return;
    }
    await records.update(
      upload.transferId,
      state: FileTransferState.verifying,
      committed: upload.committed,
    );
    try {
      final path = await upload.publish();
      session.uploads.remove(upload.transferId);
      await records.completeUpload(upload, path);
      session.send(WebFrame.state, {
        'id': upload.transferId,
        'state': WebUploadState.done,
      });
      unawaited(notifyFileVisibleToAndroidPickers(path));
    } on Object catch (error) {
      _log(WebTransferEvent.failed, error: error);
      session.send(WebFrame.state, {
        'id': upload.transferId,
        'state': WebUploadState.failed,
      });
      await _failUpload(session, upload, FileTransferState.failed);
    }
  }

  /// A `PUT` failed for want of space.
  Future<void> refuseUpload(WebSession session, WebUpload upload) async {
    session.send(WebFrame.state, {
      'id': upload.transferId,
      'state': WebUploadState.refused,
      'reason': 'space',
    });
    await _failUpload(session, upload, FileTransferState.failed);
  }

  // Internals

  /// Takes `/` and `/w/` on the share link server, whether or not it runs.
  /// From app start, so a page that comes back after a restart hears that its
  /// visit is over instead of retrying.
  void install() {
    if (!_installed) {
      _installed = true;
      links.server.extension = routes;
    }
  }

  Future<void> _releaseIfIdle() async {
    if (!_hosting && _sessions.isEmpty) {
      await links.hold(false);
    }
  }

  Future<WebSession?> _hello(
    WebSocket socket,
    String client,
    WebHello hello,
  ) async {
    final uid = webVisitorUid(hello.key);
    final known = _sessions[uid];
    if (known != null) {
      // The same browser: back after a break, or another tab taking over.
      final old = known.socket;
      known
        ..socket = socket
        ..client = client
        ..hello = hello;
      if (old != null && !identical(old, socket)) {
        unawaited(old.close(WebSocketStatus.normalClosure).catchError((_) {}));
      }
      if (known.phase == WebSessionPhase.pending) {
        known.send(WebFrame.wait, {
          'code': known.code,
          'host': await hostLooks(),
        });
        return known;
      }
      known
        ..cancelDeadline()
        ..phase = WebSessionPhase.online;
      await records.saveVisitor(known, online: true);
      notifyListeners();
      await _welcome(known);
      return known;
    }
    final host = await hostLooks();
    if (!_hosting) {
      socket.add(encodeWebFrame(WebFrame.closed, {'host': host}));
      await socket.close(WebSocketStatus.normalClosure);
      return null;
    }
    final pending = _sessions.values
        .where((s) => s.phase == WebSessionPhase.pending)
        .toList();
    if (_sessions.length >= maxSessions ||
        pending.length >= maxPending ||
        pending.any((s) => s.client == client) ||
        links.server.limiter.blockedFor(client) != null) {
      socket.add(encodeWebFrame(WebFrame.busy));
      await socket.close(WebSocketStatus.normalClosure);
      return null;
    }
    final session = WebSession(uid: uid, hello: hello, client: client)
      ..socket = socket;
    _sessions[uid] = session;
    session.deadline = Timer(answerTimeout, () => _expire(session));
    session.send(WebFrame.wait, {'code': session.code, 'host': host});
    _log(WebTransferEvent.asked);
    notifyListeners();
    return session;
  }

  Future<void> _onFrame(
    WebSession session,
    WebSocket socket,
    Map<String, Object?> frame,
  ) async {
    if (!identical(session.socket, socket)) {
      return;
    }
    final type = frame['t'];
    if (type == WebFrame.bye) {
      if (session.phase == WebSessionPhase.pending) {
        _drop(session, null);
      } else {
        await _end(session, 'me');
      }
      return;
    }
    if (!session.live) {
      return;
    }
    switch (type) {
      case WebFrame.text:
        await _receiveText(session, frame);
      case WebFrame.offer:
        final offer = WebOffer.parse(frame);
        final modified = frame['modified'];
        if (offer != null) {
          await _receiveOffer(
            session,
            offer,
            modified is int && modified > 0
                ? DateTime.fromMillisecondsSinceEpoch(modified)
                : null,
          );
        }
      case WebFrame.cancel:
        final upload = session.uploads[frame['id']];
        if (upload != null) {
          await _failUpload(session, upload, FileTransferState.canceled);
        }
    }
  }

  Future<void> _receiveText(
    WebSession session,
    Map<String, Object?> frame,
  ) async {
    final id = frame['id'];
    final body = frame['body'];
    if (!WebOffer.isId(id) ||
        body is! String ||
        body.trim().isEmpty ||
        body.length > webMaxTextBytes) {
      return;
    }
    await records.ensureVisitor(session);
    final self = await _self();
    await records.addText(
      sender: session.uid,
      receiver: self.uid,
      text: body,
      uuid: id as String,
      acked: true,
    );
    session.send(WebFrame.ack, {
      'id': id,
      'time': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> _receiveOffer(
    WebSession session,
    WebOffer offer,
    DateTime? modified,
  ) async {
    final resumed = session.uploads[offer.id];
    if (resumed != null) {
      session.send(WebFrame.state, {
        'id': offer.id,
        'state': WebUploadState.ready,
        'committed': resumed.committed,
      });
      return;
    }
    final existing = await records.db.fetchFileTransfer(offer.id);
    if (existing != null) {
      // Sent before, or an id that is not this visitor's to use.
      final done =
          existing.peerUid == session.uid &&
          existing.state == FileTransferState.completed;
      session.send(WebFrame.state, {
        'id': offer.id,
        'state': done ? WebUploadState.done : WebUploadState.failed,
      });
      return;
    }
    final upload = WebUpload(
      offer: offer,
      directory: await _receiveDirectory(),
      transferId: offer.id,
      modified: modified,
    );
    try {
      await upload.open();
    } on FileSystemException catch (error) {
      _log(WebTransferEvent.failed, error: error);
      session.send(WebFrame.state, {
        'id': offer.id,
        'state': WebUploadState.failed,
      });
      return;
    }
    await records.ensureVisitor(session);
    final self = await _self();
    await records.addUpload(
      session: session,
      receiver: self.uid,
      upload: upload,
    );
    session.uploads[offer.id] = upload;
    session.send(WebFrame.state, {
      'id': offer.id,
      'state': WebUploadState.ready,
      'committed': 0,
    });
  }

  Future<void> _failUpload(
    WebSession session,
    WebUpload upload,
    FileTransferState state,
  ) async {
    session.uploads.remove(upload.transferId);
    await upload.discard();
    await records.update(
      upload.transferId,
      state: state,
      committed: upload.committed,
    );
  }

  Future<void> _welcome(WebSession session) async {
    final history = await records.history(session);
    session.send(WebFrame.welcome, {
      'session': session.token,
      'host': await hostLooks(),
      'history': history,
    });
  }

  void _socketGone(WebSession session) {
    session.socket = null;
    switch (session.phase) {
      case WebSessionPhase.pending:
        // Reloaded, or the phone switched apps: the question stays, with the
        // same digits, until it is answered or runs out. Only `bye` (the
        // page's cancel) takes it back at once.
        break;
      case WebSessionPhase.online:
        session
          ..phase = WebSessionPhase.away
          ..deadline = Timer(awayTimeout, () => _end(session, 'expired'));
        unawaited(records.saveVisitor(session, online: false));
        notifyListeners();
      case WebSessionPhase.away || WebSessionPhase.ended:
        break;
    }
  }

  void _expire(WebSession session) {
    if (session.phase != WebSessionPhase.pending) {
      return;
    }
    links.server.limiter.fail(session.client);
    _drop(session, WebFrame.expired);
  }

  /// A request that never became a visit.
  void _drop(WebSession session, String? frame) {
    session
      ..cancelDeadline()
      ..phase = WebSessionPhase.ended
      ..hangUp(frame);
    _sessions.remove(session.uid);
    notifyListeners();
    unawaited(_releaseIfIdle());
  }

  /// [by] is `host`, `me` (the page said bye) or `expired`.
  Future<void> _end(WebSession session, String by) async {
    if (session.phase == WebSessionPhase.ended) {
      return;
    }
    final wasAllowed = session.allowed;
    session
      ..cancelDeadline()
      ..phase = WebSessionPhase.ended
      ..hangUp(by == 'me' ? null : WebFrame.ended, {'by': by});
    _sessions.remove(session.uid);
    for (final socket in session.downloads.toList()) {
      socket.destroy();
    }
    session.downloads.clear();
    for (final upload in session.uploads.values.toList()) {
      await _failUpload(session, upload, FileTransferState.failed);
    }
    if (wasAllowed) {
      await records.saveVisitor(session, online: false);
    }
    _log(WebTransferEvent.ended);
    notifyListeners();
    await _releaseIfIdle();
  }

  Future<String> _keep(String path) async {
    final directory = await _receiveDirectory();
    final extension = p.extension(path);
    final stem = p.basenameWithoutExtension(path);
    var target = File(p.join(directory.path, '$stem$extension'));
    for (var suffix = 2; await target.exists(); suffix++) {
      target = File(p.join(directory.path, '$stem-$suffix$extension'));
    }
    await File(path).copy(target.path);
    return target.path;
  }

  void _log(WebTransferEvent event, {Object? error}) {
    privacyLog.event(PrivacyEvent.localOperation, <PrivacyField, Object>{
      PrivacyField.kind: event,
      PrivacyField.success: error == null,
      if (error != null) PrivacyField.errorType: privacyLog.errorType(error),
    });
  }
}
