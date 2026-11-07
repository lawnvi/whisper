import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:whisper/helper/desktop_clipboard_image.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/remote_files/fs_placement.dart';
import 'package:whisper/socket/peer_connection.dart';
import 'package:whisper/socket/whisper_frame_v3.dart';

// Files sent as clipboard frames, held in memory along the way: what older
// devices take, and what a screenshot uses.
const int remoteClipboardMaxFileBytes = 64 * 1024 * 1024;
const int remoteClipboardMaxBatchBytes = 128 * 1024 * 1024;
const int remoteClipboardMaxItems = 20;
const int remoteClipboardChunkBytes = 512 * 1024;

// Files sent as ordinary file transfers, between devices that both can: the
// disk is the limit, not memory.
const int remoteClipboardTransferMaxFileBytes = 64 * 1024 * 1024 * 1024;
const int remoteClipboardTransferMaxBatchBytes = 256 * 1024 * 1024 * 1024;
// Each item is one transfer, and a device keeps at most 32 unfinished
// (`maxNonterminalTransfersPerPeer`): room is left for others.
const int remoteClipboardTransferMaxItems = 20;

/// A transfer that has made no progress this long has stalled.
const Duration remoteClipboardTransferStallLimit = Duration(seconds: 60);

void traceRemoteClipboard(
  String stage, {
  int? count,
  bool? success,
  String? reason,
}) {
  final enabled =
      Platform.environment['WHISPER_REMOTE_INPUT_TRACE'] == '1' ||
      (!kReleaseMode && Platform.resolvedExecutable.endsWith('/whisper'));
  if (!enabled) {
    return;
  }
  final line =
      '[remote-clipboard]'
      ' time=${DateTime.now().toIso8601String()}'
      ' pid=$pid stage=$stage'
      '${count == null ? '' : ' count=$count'}'
      '${success == null ? '' : ' success=$success'}'
      '${reason == null ? '' : ' reason=$reason'}';
  privacyLog.event(PrivacyEvent.remoteInputDiagnostic, {
    PrivacyField.component: _privacyTraceCode('remote_clipboard'),
    PrivacyField.action: _privacyTraceCode(stage),
    if (count != null) PrivacyField.count: count,
    if (success != null) PrivacyField.success: success,
    if (reason != null) PrivacyField.reason: _privacyTraceCode(reason),
  });
  try {
    File(
      p.join(Directory.systemTemp.path, 'whisper_remote_clipboard_trace.log'),
    ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } on FileSystemException {
    // Diagnostics must never affect clipboard delivery.
  }
}

int _privacyTraceCode(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0x7fffffff;
  }
  return hash;
}

enum RemoteClipboardPasteResult { notAvailable, prepared, failed }

typedef RemoteClipboardFrameSender =
    Future<bool> Function(
      TransferConnectionBinding binding,
      WhisperFrameV3 frame,
    );
typedef RemoteClipboardBindingProvider =
    TransferConnectionBinding? Function(String peerId);
typedef RemoteClipboardSessionValidator =
    bool Function({
      required String peerId,
      required String sessionId,
      required bool sourceIsLocal,
    });
typedef RemoteClipboardDirectoryProvider = Future<Directory> Function();

/// Sends the file at [path] as a quiet file transfer with id [transferId].
typedef RemoteClipboardFileSender =
    Future<bool> Function(String peerId, String path, String transferId);

final class RemoteClipboardLocalItem {
  const RemoteClipboardLocalItem({
    required this.name,
    required this.size,
    required this.openRead,
    this.isImage = false,
    this.resolvePath,
  });

  factory RemoteClipboardLocalItem.file(ClipboardFileDraft draft) {
    return RemoteClipboardLocalItem(
      name: draft.fileName,
      size: draft.size,
      openRead: () => File(draft.path).openRead(),
      resolvePath: () async => draft.path,
    );
  }

  factory RemoteClipboardLocalItem.bytes(String name, Uint8List bytes) {
    return RemoteClipboardLocalItem(
      name: name,
      size: bytes.length,
      openRead: () => Stream<List<int>>.value(bytes),
      isImage: true,
    );
  }

  final String name;
  final int size;
  final Stream<List<int>> Function() openRead;
  final bool isImage;

  /// A file on disk with this content, for sending it as a file transfer.
  /// Null when it has none (image bytes): it then goes as frames.
  final Future<String> Function()? resolvePath;
}

final class RemoteClipboardOfferItem {
  const RemoteClipboardOfferItem({
    required this.name,
    required this.size,
    required this.isImage,
  });

  final String name;
  final int size;
  final bool isImage;
}

final class RemoteClipboardOfferSnapshot {
  const RemoteClipboardOfferSnapshot({
    required this.offerId,
    required this.sessionId,
    required this.peerId,
    required this.items,
  });

  final String offerId;
  final String sessionId;
  final String peerId;
  final List<RemoteClipboardOfferItem> items;
}

final class RemoteClipboardTransferEngine {
  RemoteClipboardTransferEngine({
    required RemoteClipboardFrameSender sendFrame,
    required RemoteClipboardBindingProvider currentBinding,
    required RemoteClipboardSessionValidator sessionValidator,
    DesktopClipboardFileWriter writer = const DesktopClipboardFileWriter(),
    RemoteClipboardDirectoryProvider? directoryProvider,
    Duration requestTimeout = const Duration(minutes: 2),
    Duration cacheTtl = const Duration(minutes: 10),
    Uuid uuid = const Uuid(),
    RemoteClipboardFileSender? sendFile,
    Future<void> Function(String transferId)? cancelTransfer,
    TransferPlacements? placements,
  }) : _sendFrame = sendFrame,
       _currentBinding = currentBinding,
       _sessionValidator = sessionValidator,
       _writer = writer,
       _directoryProvider = directoryProvider ?? _defaultDirectory,
       _requestTimeout = requestTimeout,
       _cacheTtl = cacheTtl,
       _uuid = uuid,
       _sendFile = sendFile,
       _cancelTransfer = cancelTransfer,
       _placements = placements;

  static const int protocolVersion = 1;

  final RemoteClipboardFrameSender _sendFrame;
  final RemoteClipboardBindingProvider _currentBinding;
  final RemoteClipboardSessionValidator _sessionValidator;
  final DesktopClipboardFileWriter _writer;
  final RemoteClipboardDirectoryProvider _directoryProvider;
  final Duration _requestTimeout;
  final Duration _cacheTtl;
  final Uuid _uuid;

  /// Files go as file transfers when both ends can: fast, and as large as
  /// the disk allows. Without these, every file goes as frames.
  final RemoteClipboardFileSender? _sendFile;
  final Future<void> Function(String transferId)? _cancelTransfer;
  final TransferPlacements? _placements;

  bool get _sendsTransfers =>
      _sendFile != null && _cancelTransfer != null && _placements != null;
  final Map<String, _TransferRequest> _transferRequests =
      <String, _TransferRequest>{};
  StreamSubscription<PlacedTransfer>? _placedSubscription;
  StreamSubscription<TransferSnapshot>? _updateSubscription;

  final Map<String, _SourceOffer> _sourceOffers = <String, _SourceOffer>{};
  final Map<String, _RemoteOffer> _remoteOffers = <String, _RemoteOffer>{};
  final Map<String, _IncomingRequest> _incoming = <String, _IncomingRequest>{};
  final Map<String, _CachedPaste> _cached = <String, _CachedPaste>{};
  final Map<String, Timer> _cacheTimers = <String, Timer>{};
  final Map<_RemoteOffer, Future<RemoteClipboardPasteResult>>
  _materializations = <_RemoteOffer, Future<RemoteClipboardPasteResult>>{};
  _RemoteOffer? _latestRemoteOffer;

  Future<bool> publish({
    required String peerId,
    required String sessionId,
    required List<RemoteClipboardLocalItem> items,
  }) async {
    traceRemoteClipboard('publish_start', count: items.length);
    if (!_sessionValidator(
      peerId: peerId,
      sessionId: sessionId,
      sourceIsLocal: true,
    )) {
      traceRemoteClipboard('publish_rejected', reason: 'session');
      return false;
    }
    final viaTransfer =
        _sendsTransfers &&
        items.isNotEmpty &&
        items.every((item) => item.resolvePath != null);
    final normalized = _validatedLocalItems(items, viaTransfer: viaTransfer);
    if (normalized == null) {
      traceRemoteClipboard('publish_rejected', reason: 'limits');
      await clearSession(sessionId, notifyPeer: true, peerId: peerId);
      return false;
    }
    _sourceOffers.remove(sessionId);
    final offerId = _uuid.v4();
    final offer = _SourceOffer(
      offerId: offerId,
      sessionId: sessionId,
      peerId: peerId,
      items: normalized,
    );
    _sourceOffers[sessionId] = offer;
    final binding = _currentBinding(peerId);
    if (binding == null) {
      traceRemoteClipboard('publish_rejected', reason: 'connection');
      _sourceOffers.remove(sessionId);
      return false;
    }
    if (viaTransfer && _validatedLocalItems(items, viaTransfer: false) == null) {
      // An older device turns this offer down and would keep pasting the
      // previous one: it hears that the clipboard was cleared first.
      await _sendFrame(
        binding,
        WhisperFrameV3(
          type: WhisperFrameType.clipboardClear,
          transferId: '',
          offset: 0,
          sequence: 0,
          payload: _jsonBytes(<String, Object?>{
            'protocolVersion': protocolVersion,
            'sessionId': sessionId,
          }),
        ),
      );
    }
    final sent = await _sendFrame(
      binding,
      WhisperFrameV3(
        type: WhisperFrameType.clipboardOffer,
        transferId: offerId,
        offset: 0,
        sequence: 0,
        payload: _jsonBytes(<String, Object?>{
          'protocolVersion': protocolVersion,
          'sessionId': sessionId,
          'items': <Map<String, Object?>>[
            for (final item in normalized)
              <String, Object?>{
                'name': item.name,
                'size': item.size,
                'kind': item.isImage ? 'image' : 'file',
              },
          ],
          // Older devices ignore it and ask for frames.
          if (viaTransfer) 'viaTransfer': true,
        }),
      ),
    );
    if (!sent && identical(_sourceOffers[sessionId], offer)) {
      _sourceOffers.remove(sessionId);
    }
    traceRemoteClipboard('offer_sent', success: sent);
    return sent;
  }

  Future<void> clearSession(
    String sessionId, {
    bool notifyPeer = false,
    String peerId = '',
  }) async {
    _sourceOffers.remove(sessionId);
    final remote = _remoteOffers[sessionId];
    final cleanup = _removeRemoteOffer(sessionId);
    try {
      if (notifyPeer && peerId.isNotEmpty) {
        final binding = _currentBinding(peerId);
        if (binding != null) {
          await _sendFrame(
            binding,
            WhisperFrameV3(
              type: WhisperFrameType.clipboardClear,
              transferId: remote?.offerId ?? '',
              offset: 0,
              sequence: 0,
              payload: _jsonBytes(<String, Object?>{
                'protocolVersion': protocolVersion,
                'sessionId': sessionId,
              }),
            ),
          );
        }
      }
    } finally {
      await cleanup;
    }
  }

  Future<void> clearPeer(String peerId) async {
    final sessionIds = <String>{
      for (final offer in _sourceOffers.values)
        if (offer.peerId == peerId) offer.sessionId,
      for (final offer in _remoteOffers.values)
        if (offer.peerId == peerId) offer.sessionId,
    };
    await Future.wait(sessionIds.map(clearSession));
  }

  Future<RemoteClipboardPasteResult> preparePaste({
    required String peerId,
    required String sessionId,
  }) async {
    traceRemoteClipboard('paste_prepare_start');
    if (!_sessionValidator(
      peerId: peerId,
      sessionId: sessionId,
      sourceIsLocal: false,
    )) {
      traceRemoteClipboard('paste_unavailable', reason: 'session');
      return RemoteClipboardPasteResult.notAvailable;
    }
    final offer = _remoteOffers[sessionId];
    if (offer == null || offer.peerId != peerId) {
      traceRemoteClipboard('paste_unavailable', reason: 'offer');
      return RemoteClipboardPasteResult.notAvailable;
    }
    final materialized = await _materializeRemoteOffer(offer);
    if (!_isCurrentRemoteOffer(offer) ||
        !identical(_latestRemoteOffer, offer)) {
      return RemoteClipboardPasteResult.notAvailable;
    }
    if (materialized != RemoteClipboardPasteResult.prepared) {
      traceRemoteClipboard('paste_prepare_done', reason: materialized.name);
      return materialized;
    }
    final cached = _cached[sessionId];
    if (cached == null || cached.offerId != offer.offerId) {
      return RemoteClipboardPasteResult.failed;
    }
    final written = await _writer.writeFilePaths(
      cached.paths,
      asImage: cached.asImage,
    );
    traceRemoteClipboard('clipboard_written', success: written);
    final result = written
        ? RemoteClipboardPasteResult.prepared
        : RemoteClipboardPasteResult.failed;
    traceRemoteClipboard('paste_prepare_done', reason: result.name);
    return result;
  }

  Future<RemoteClipboardPasteResult> _materializeRemoteOffer(
    _RemoteOffer offer,
  ) async {
    final pending = _materializations[offer];
    if (pending != null) {
      return pending;
    }
    final download = _downloadRemoteOffer(offer);
    _materializations[offer] = download;
    try {
      return await download;
    } catch (error) {
      final request = _incoming[offer.sessionId];
      if (request != null && identical(request.offer, offer)) {
        _incoming.remove(offer.sessionId);
        request.complete(RemoteClipboardPasteResult.failed);
        await request.dispose(deleteDirectory: true);
      }
      traceRemoteClipboard(
        'paste_download_failed',
        reason: error.runtimeType.toString(),
      );
      return RemoteClipboardPasteResult.failed;
    } finally {
      _materializations.remove(offer);
    }
  }

  bool _isCurrentRemoteOffer(_RemoteOffer offer) {
    return identical(_remoteOffers[offer.sessionId], offer) &&
        _sessionValidator(
          peerId: offer.peerId,
          sessionId: offer.sessionId,
          sourceIsLocal: false,
        );
  }

  Future<RemoteClipboardPasteResult> _downloadRemoteOffer(
    _RemoteOffer offer,
  ) async {
    if (!_isCurrentRemoteOffer(offer)) {
      return RemoteClipboardPasteResult.notAvailable;
    }
    final sessionId = offer.sessionId;
    final peerId = offer.peerId;
    final cached = _cached[sessionId];
    if (cached != null &&
        cached.offerId == offer.offerId &&
        !cached.isExpired(_cacheTtl) &&
        await cached.filesExist()) {
      return RemoteClipboardPasteResult.prepared;
    }
    if (!_isCurrentRemoteOffer(offer)) {
      return RemoteClipboardPasteResult.notAvailable;
    }
    if (offer.viaTransfer && _placements != null && _cancelTransfer != null) {
      return _downloadAsTransfers(offer);
    }
    final existing = _incoming[sessionId];
    if (existing != null && existing.offer.offerId == offer.offerId) {
      return existing.completion.future.timeout(
        _requestTimeout,
        onTimeout: () => RemoteClipboardPasteResult.failed,
      );
    }
    await _removeCached(sessionId);
    if (!_isCurrentRemoteOffer(offer)) {
      return RemoteClipboardPasteResult.notAvailable;
    }
    if (existing != null) {
      existing.complete(RemoteClipboardPasteResult.failed);
      await existing.dispose(deleteDirectory: true);
    }
    final base = await _directoryProvider();
    final directory = Directory(
      p.join(base.path, 'whisper_remote_clipboard', sessionId, offer.offerId),
    );
    await directory.create(recursive: true);
    final request = await _IncomingRequest.create(offer, directory);
    // A local copy, new offer or disconnect can supersede this download while
    // its temporary files are being opened.
    if (!_isCurrentRemoteOffer(offer)) {
      await request.dispose(deleteDirectory: true);
      return RemoteClipboardPasteResult.notAvailable;
    }
    _incoming[sessionId] = request;
    final binding = _currentBinding(peerId);
    if (binding == null ||
        !await _sendFrame(
          binding,
          WhisperFrameV3(
            type: WhisperFrameType.clipboardRequest,
            transferId: offer.offerId,
            offset: 0,
            sequence: 0,
            payload: _jsonBytes(<String, Object?>{
              'protocolVersion': protocolVersion,
              'sessionId': sessionId,
            }),
          ),
        )) {
      traceRemoteClipboard('request_sent', success: false);
      if (identical(_incoming[sessionId], request)) {
        _incoming.remove(sessionId);
      }
      request.complete(RemoteClipboardPasteResult.failed);
      await request.dispose(deleteDirectory: true);
      return RemoteClipboardPasteResult.failed;
    }
    traceRemoteClipboard('request_sent', success: true);
    final result = await request.completion.future.timeout(
      _requestTimeout,
      onTimeout: () => RemoteClipboardPasteResult.failed,
    );
    if (result == RemoteClipboardPasteResult.failed &&
        identical(_incoming[sessionId], request)) {
      _incoming.remove(sessionId);
      await request.dispose(deleteDirectory: true);
    }
    return result;
  }

  RemoteClipboardOfferSnapshot? remoteOffer({
    required String peerId,
    required String sessionId,
  }) {
    final offer = _remoteOffers[sessionId];
    if (offer == null || offer.peerId != peerId) {
      return null;
    }
    return RemoteClipboardOfferSnapshot(
      offerId: offer.offerId,
      sessionId: offer.sessionId,
      peerId: offer.peerId,
      items: List<RemoteClipboardOfferItem>.unmodifiable(
        offer.items.map(
          (item) => RemoteClipboardOfferItem(
            name: item.name,
            size: item.size,
            isImage: item.isImage,
          ),
        ),
      ),
    );
  }

  Future<bool> relayRemoteOffer({
    required String originPeerId,
    required String originSessionId,
    required String targetPeerId,
    required String targetSessionId,
  }) async {
    final origin = _remoteOffers[originSessionId];
    if (origin == null || origin.peerId != originPeerId) {
      return false;
    }
    final items = <RemoteClipboardLocalItem>[];
    for (var index = 0; index < origin.items.length; index++) {
      final item = origin.items[index];
      items.add(
        RemoteClipboardLocalItem(
          name: item.name,
          size: item.size,
          isImage: item.isImage,
          openRead: () => _openRelayedItem(origin, index),
        ),
      );
    }
    return publish(
      peerId: targetPeerId,
      sessionId: targetSessionId,
      items: items,
    );
  }

  Stream<List<int>> _openRelayedItem(_RemoteOffer offer, int index) async* {
    if (!identical(_remoteOffers[offer.sessionId], offer)) {
      throw const FileSystemException('workspace clipboard offer changed');
    }
    final result = await _materializeRemoteOffer(offer);
    final cached = _cached[offer.sessionId];
    if (result != RemoteClipboardPasteResult.prepared ||
        cached == null ||
        cached.offerId != offer.offerId ||
        index < 0 ||
        index >= cached.paths.length) {
      throw const FileSystemException('workspace clipboard relay failed');
    }
    yield* File(cached.paths[index]).openRead();
  }

  Future<void> handleFrame(
    TransferConnectionBinding binding,
    WhisperFrameV3 frame, {
    bool prepareImages = false,
  }) async {
    traceRemoteClipboard('frame_received', reason: frame.type.name);
    switch (frame.type) {
      case WhisperFrameType.clipboardOffer:
        await _handleOffer(binding, frame);
        if (prepareImages) {
          final offer = _remoteOffers.values
              .where(
                (offer) =>
                    offer.offerId == frame.transferId &&
                    offer.peerId == binding.peerId,
              )
              .firstOrNull;
          if (offer != null &&
              offer.items.length == 1 &&
              offer.items.single.isImage) {
            // Completion/data and edge-release/stop controls use this same
            // receive queue. Never wait for the download inside its handler.
            unawaited(_prepareImageOffer(offer));
          }
        }
        return;
      case WhisperFrameType.clipboardClear:
        await _handleClear(binding, frame);
        return;
      case WhisperFrameType.clipboardRequest:
        await _handleRequest(binding, frame);
        return;
      case WhisperFrameType.clipboardData:
        await _handleData(binding, frame);
        return;
      case WhisperFrameType.clipboardComplete:
        await _handleComplete(binding, frame);
        return;
      case WhisperFrameType.clipboardError:
        await _handleError(binding, frame);
        return;
      default:
        throw const FormatException('not a remote clipboard frame');
    }
  }

  Future<void> _prepareImageOffer(_RemoteOffer offer) async {
    try {
      await preparePaste(peerId: offer.peerId, sessionId: offer.sessionId);
    } catch (error) {
      traceRemoteClipboard(
        'image_prepare_failed',
        reason: error.runtimeType.toString(),
      );
    }
  }

  Future<void> _handleOffer(
    TransferConnectionBinding binding,
    WhisperFrameV3 frame,
  ) async {
    final json = _frameJson(frame);
    final sessionId = json['sessionId'];
    final rawItems = json['items'];
    if (json['protocolVersion'] != protocolVersion ||
        sessionId is! String ||
        sessionId.isEmpty ||
        rawItems is! List ||
        frame.transferId.isEmpty ||
        frame.offset != 0 ||
        frame.sequence != 0 ||
        !_sessionValidator(
          peerId: binding.peerId,
          sessionId: sessionId,
          sourceIsLocal: false,
        )) {
      throw const FormatException('invalid remote clipboard offer');
    }
    final viaTransfer = json['viaTransfer'] == true;
    final limits = _limits(viaTransfer);
    final items = <_RemoteItem>[];
    var total = 0;
    for (final raw in rawItems) {
      if (raw is! Map) {
        throw const FormatException('invalid remote clipboard item');
      }
      final item = Map<String, dynamic>.from(raw);
      final name = item['name'];
      final size = item['size'];
      final kind = item['kind'];
      if (name is! String ||
          !_isSafeName(name) ||
          size is! int ||
          (kind != 'file' && kind != 'image') ||
          size < 0 ||
          size > limits.file) {
        throw const FormatException('invalid remote clipboard item');
      }
      total += size;
      items.add(_RemoteItem(name: name, size: size, isImage: kind == 'image'));
    }
    if (items.isEmpty || items.length > limits.items || total > limits.batch) {
      throw const FormatException('remote clipboard offer exceeds limits');
    }
    await _replaceRemoteOffer(
      _RemoteOffer(
        offerId: frame.transferId,
        sessionId: sessionId,
        peerId: binding.peerId,
        items: items,
        viaTransfer: viaTransfer,
      ),
    );
    traceRemoteClipboard('offer_received', count: items.length);
  }

  Future<void> _handleClear(
    TransferConnectionBinding binding,
    WhisperFrameV3 frame,
  ) async {
    final json = _frameJson(frame);
    final sessionId = json['sessionId'];
    if (json['protocolVersion'] != protocolVersion || sessionId is! String) {
      throw const FormatException('invalid remote clipboard clear');
    }
    final offer = _remoteOffers[sessionId];
    if (offer != null && offer.peerId == binding.peerId) {
      await _removeRemoteOffer(sessionId);
    }
  }

  Future<void> _handleRequest(
    TransferConnectionBinding binding,
    WhisperFrameV3 frame,
  ) async {
    final json = _frameJson(frame);
    final sessionId = json['sessionId'];
    final offer = sessionId is String ? _sourceOffers[sessionId] : null;
    if (json['protocolVersion'] != protocolVersion ||
        offer == null ||
        offer.peerId != binding.peerId ||
        offer.offerId != frame.transferId ||
        !_sessionValidator(
          peerId: binding.peerId,
          sessionId: offer.sessionId,
          sourceIsLocal: true,
        )) {
      await _sendError(binding, frame.transferId, sessionId as String? ?? '');
      traceRemoteClipboard('request_rejected');
      return;
    }
    traceRemoteClipboard('request_received');
    final transferIds = _transferIdsFrom(json['transferIds'], offer.items);
    if (transferIds != null) {
      unawaited(_sendAsTransfers(binding, offer, transferIds));
      return;
    }
    unawaited(_streamOffer(binding, offer));
  }

  /// The ids an asking device chose for the transfers, one per item, when it
  /// takes them and this device can send them.
  List<String>? _transferIdsFrom(
    Object? raw,
    List<RemoteClipboardLocalItem> items,
  ) {
    if (!_sendsTransfers ||
        raw is! List ||
        raw.length != items.length ||
        items.any((item) => item.resolvePath == null)) {
      return null;
    }
    final ids = <String>[];
    for (final value in raw) {
      if (value is! String || !_uuidPattern.hasMatch(value)) {
        return null;
      }
      ids.add(value);
    }
    return ids.toSet().length == ids.length ? ids : null;
  }

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  Future<void> _sendAsTransfers(
    TransferConnectionBinding binding,
    _SourceOffer offer,
    List<String> transferIds,
  ) async {
    traceRemoteClipboard('transfers_start', count: offer.items.length);
    try {
      for (var index = 0; index < offer.items.length; index++) {
        if (!identical(_sourceOffers[offer.sessionId], offer)) {
          throw const FileSystemException('clipboard offer replaced');
        }
        final path = await offer.items[index].resolvePath!();
        if (!await _sendFile!(offer.peerId, path, transferIds[index])) {
          throw const FileSystemException('clipboard transfer not sent');
        }
      }
      traceRemoteClipboard('transfers_sent', success: true);
    } catch (error) {
      traceRemoteClipboard(
        'transfers_sent',
        success: false,
        reason: error.runtimeType.toString(),
      );
      await _sendError(binding, offer.offerId, offer.sessionId);
    }
  }

  Future<void> _streamOffer(
    TransferConnectionBinding binding,
    _SourceOffer offer,
  ) async {
    traceRemoteClipboard('stream_start', count: offer.items.length);
    try {
      for (var index = 0; index < offer.items.length; index++) {
        final item = offer.items[index];
        var offset = 0;
        await for (final block in item.openRead()) {
          var start = 0;
          while (start < block.length) {
            final end = (start + remoteClipboardChunkBytes).clamp(
              0,
              block.length,
            );
            final chunk = Uint8List.fromList(block.sublist(start, end));
            if (chunk.isEmpty || offset + chunk.length > item.size) {
              throw const FileSystemException('clipboard source size changed');
            }
            final current = _sourceOffers[offer.sessionId];
            if (!identical(current, offer) ||
                _currentBinding(offer.peerId) != binding ||
                !await _sendFrame(
                  binding,
                  WhisperFrameV3(
                    type: WhisperFrameType.clipboardData,
                    transferId: offer.offerId,
                    offset: offset,
                    sequence: index,
                    payload: chunk,
                  ),
                )) {
              throw const FileSystemException('clipboard peer disconnected');
            }
            offset += chunk.length;
            start = end;
          }
        }
        if (offset != item.size) {
          throw const FileSystemException('clipboard source size changed');
        }
      }
      await _sendFrame(
        binding,
        WhisperFrameV3(
          type: WhisperFrameType.clipboardComplete,
          transferId: offer.offerId,
          offset: offer.items.fold<int>(0, (sum, item) => sum + item.size),
          sequence: offer.items.length,
          payload: _jsonBytes(<String, Object?>{
            'protocolVersion': protocolVersion,
            'sessionId': offer.sessionId,
          }),
        ),
      );
      traceRemoteClipboard('stream_complete', success: true);
    } catch (error) {
      traceRemoteClipboard(
        'stream_complete',
        success: false,
        reason: error.runtimeType.toString(),
      );
      await _sendError(binding, offer.offerId, offer.sessionId);
    }
  }

  Future<void> _handleData(
    TransferConnectionBinding binding,
    WhisperFrameV3 frame,
  ) async {
    if (frame.payload.isEmpty ||
        frame.payload.length > remoteClipboardChunkBytes) {
      throw const FormatException('invalid remote clipboard data');
    }
    final request = _incoming.values
        .where((item) => item.offer.offerId == frame.transferId)
        .firstOrNull;
    if (request == null || request.offer.peerId != binding.peerId) {
      return;
    }
    try {
      await request.add(frame);
    } catch (_) {
      if (!identical(_incoming[request.offer.sessionId], request)) {
        return;
      }
      _incoming.remove(request.offer.sessionId);
      request.complete(RemoteClipboardPasteResult.failed);
      await request.dispose(deleteDirectory: true);
      rethrow;
    }
  }

  Future<void> _handleComplete(
    TransferConnectionBinding binding,
    WhisperFrameV3 frame,
  ) async {
    final json = _frameJson(frame);
    final sessionId = json['sessionId'];
    if (json['protocolVersion'] != protocolVersion || sessionId is! String) {
      throw const FormatException('invalid remote clipboard completion');
    }
    final request = _incoming[sessionId];
    // A screenshot can be replaced or cancelled while its last frames are
    // already on the wire; those frames must not tear down the peer session.
    if (request == null ||
        request.offer.peerId != binding.peerId ||
        request.offer.offerId != frame.transferId) {
      return;
    }
    if (frame.sequence != request.offer.items.length ||
        frame.offset != request.offer.totalSize) {
      throw const FormatException('invalid remote clipboard completion');
    }
    _incoming.remove(sessionId);
    try {
      final paths = await request.finish();
      if (!_isCurrentRemoteOffer(request.offer)) {
        request.complete(RemoteClipboardPasteResult.notAvailable);
        await request.dispose(deleteDirectory: true);
        return;
      }
      _storeCached(request.offer, request.directory, paths);
      request.complete(RemoteClipboardPasteResult.prepared);
      traceRemoteClipboard('cache_ready', success: true);
    } catch (error) {
      traceRemoteClipboard(
        'cache_ready',
        success: false,
        reason: error.runtimeType.toString(),
      );
      request.complete(RemoteClipboardPasteResult.failed);
      await request.dispose(deleteDirectory: true);
    }
  }

  Future<void> _handleError(
    TransferConnectionBinding binding,
    WhisperFrameV3 frame,
  ) async {
    final json = _frameJson(frame);
    final sessionId = json['sessionId'];
    final request = sessionId is String ? _incoming[sessionId] : null;
    if (request == null ||
        request.offer.peerId != binding.peerId ||
        request.offer.offerId != frame.transferId) {
      return;
    }
    _incoming.remove(sessionId);
    request.complete(RemoteClipboardPasteResult.failed);
    await request.dispose(deleteDirectory: true);
  }

  Future<void> _sendError(
    TransferConnectionBinding binding,
    String offerId,
    String sessionId,
  ) {
    return _sendFrame(
      binding,
      WhisperFrameV3(
        type: WhisperFrameType.clipboardError,
        transferId: offerId,
        offset: 0,
        sequence: 0,
        payload: _jsonBytes(<String, Object?>{
          'protocolVersion': protocolVersion,
          'sessionId': sessionId,
        }),
      ),
    ).then((_) {});
  }

  List<RemoteClipboardLocalItem>? _validatedLocalItems(
    List<RemoteClipboardLocalItem> items, {
    required bool viaTransfer,
  }) {
    final limits = _limits(viaTransfer);
    if (items.isEmpty || items.length > limits.items) {
      return null;
    }
    var total = 0;
    for (final item in items) {
      if (!_isSafeName(item.name) || item.size < 0 || item.size > limits.file) {
        return null;
      }
      total += item.size;
      if (total > limits.batch) {
        return null;
      }
    }
    return List<RemoteClipboardLocalItem>.unmodifiable(items);
  }

  static ({int items, int file, int batch}) _limits(bool viaTransfer) =>
      viaTransfer
      ? (
          items: remoteClipboardTransferMaxItems,
          file: remoteClipboardTransferMaxFileBytes,
          batch: remoteClipboardTransferMaxBatchBytes,
        )
      : (
          items: remoteClipboardMaxItems,
          file: remoteClipboardMaxFileBytes,
          batch: remoteClipboardMaxBatchBytes,
        );

  void _storeCached(
    _RemoteOffer offer,
    Directory directory,
    List<String> paths,
  ) {
    final sessionId = offer.sessionId;
    final cached = _CachedPaste(
      offerId: offer.offerId,
      directory: directory,
      paths: paths,
      createdAt: DateTime.now(),
      asImage: offer.items.length == 1 && offer.items.single.isImage,
    );
    _cached[sessionId] = cached;
    _cacheTimers.remove(sessionId)?.cancel();
    _cacheTimers[sessionId] = Timer(_cacheTtl, () {
      if (identical(_cached[sessionId], cached)) {
        unawaited(_removeCached(sessionId));
      }
    });
  }

  // ---- Files that come as file transfers ----

  /// Transfers given up on before their offer arrived: cancelled as soon as
  /// they show up.
  final Set<String> _abandonedTransferIds = <String>{};

  Future<RemoteClipboardPasteResult> _downloadAsTransfers(
    _RemoteOffer offer,
  ) async {
    final sessionId = offer.sessionId;
    final existing = _transferRequests[sessionId];
    if (existing != null && existing.offer.offerId == offer.offerId) {
      return existing.completion.future;
    }
    await _removeCached(sessionId);
    if (existing != null) {
      await _abandonTransferRequest(existing);
    }
    if (!_isCurrentRemoteOffer(offer)) {
      return RemoteClipboardPasteResult.notAvailable;
    }
    final base = await _directoryProvider();
    final directory = Directory(
      p.join(base.path, 'whisper_remote_clipboard', sessionId, offer.offerId),
    );
    await directory.create(recursive: true);
    if (!_isCurrentRemoteOffer(offer) ||
        _transferRequests.containsKey(sessionId)) {
      await directory.delete(recursive: true).catchError((_) => directory);
      return _transferRequests[sessionId]?.offer.offerId == offer.offerId
          ? _transferRequests[sessionId]!.completion.future
          : RemoteClipboardPasteResult.notAvailable;
    }
    final request = _TransferRequest(
      offer: offer,
      directory: directory,
      transferIds: [for (final _ in offer.items) _uuid.v4()],
      onStalled: (request) => unawaited(_abandonTransferRequest(request)),
    );
    _transferRequests[sessionId] = request;
    _listenToTransfers();
    for (final transferId in request.transferIds) {
      _placements!.expect(transferId, directory.path);
    }
    final binding = _currentBinding(offer.peerId);
    if (binding == null ||
        !await _sendFrame(
          binding,
          WhisperFrameV3(
            type: WhisperFrameType.clipboardRequest,
            transferId: offer.offerId,
            offset: 0,
            sequence: 0,
            payload: _jsonBytes(<String, Object?>{
              'protocolVersion': protocolVersion,
              'sessionId': sessionId,
              'transferIds': request.transferIds,
            }),
          ),
        )) {
      traceRemoteClipboard('request_sent', success: false);
      await _abandonTransferRequest(request);
      return RemoteClipboardPasteResult.failed;
    }
    traceRemoteClipboard('request_sent', success: true);
    return request.completion.future;
  }

  void _listenToTransfers() {
    final placements = _placements!;
    _placedSubscription ??= placements.placed.listen(_onTransferPlaced);
    _updateSubscription ??= placements.updates.listen(_onTransferUpdated);
  }

  /// Whether [transferId] brings a pasted file here.
  bool carriesTransfer(String transferId) =>
      _transferRequestFor(transferId) != null;

  _TransferRequest? _transferRequestFor(String transferId) {
    for (final request in _transferRequests.values) {
      if (request.transferIds.contains(transferId)) {
        return request;
      }
    }
    return null;
  }

  void _onTransferPlaced(PlacedTransfer placed) {
    final request = _transferRequestFor(placed.transferId);
    if (request == null) {
      return;
    }
    request.paths[request.transferIds.indexOf(placed.transferId)] =
        placed.path;
    request.touch();
    if (request.paths.every((path) => path != null)) {
      unawaited(_finishTransferRequest(request));
    }
  }

  void _onTransferUpdated(TransferSnapshot snapshot) {
    if (snapshot.direction != FileTransferDirection.incoming) {
      return;
    }
    if (_abandonedTransferIds.contains(snapshot.transferId)) {
      if (!isTerminalFileTransferState(snapshot.state)) {
        unawaited(_cancelTransfer!(snapshot.transferId));
      } else {
        _abandonedTransferIds.remove(snapshot.transferId);
      }
      return;
    }
    final request = _transferRequestFor(snapshot.transferId);
    if (request == null) {
      return;
    }
    request.touch();
    if (snapshot.state == FileTransferState.failed ||
        snapshot.state == FileTransferState.canceled) {
      traceRemoteClipboard('transfer_failed', reason: snapshot.state.name);
      unawaited(_abandonTransferRequest(request));
    }
  }

  Future<void> _finishTransferRequest(_TransferRequest request) async {
    final sessionId = request.offer.sessionId;
    if (!identical(_transferRequests[sessionId], request)) {
      return;
    }
    _transferRequests.remove(sessionId);
    request.stop();
    if (!_isCurrentRemoteOffer(request.offer)) {
      request.complete(RemoteClipboardPasteResult.notAvailable);
      await request.directory
          .delete(recursive: true)
          .catchError((_) => request.directory);
      return;
    }
    _storeCached(
      request.offer,
      request.directory,
      List<String>.unmodifiable(request.paths.cast<String>()),
    );
    traceRemoteClipboard('cache_ready', success: true);
    request.complete(RemoteClipboardPasteResult.prepared);
  }

  /// Cancels what is still on its way and drops what arrived.
  Future<void> _abandonTransferRequest(_TransferRequest request) async {
    final sessionId = request.offer.sessionId;
    if (identical(_transferRequests[sessionId], request)) {
      _transferRequests.remove(sessionId);
    }
    request.stop();
    request.complete(RemoteClipboardPasteResult.failed);
    for (var index = 0; index < request.transferIds.length; index++) {
      if (request.paths[index] == null) {
        final transferId = request.transferIds[index];
        _abandonedTransferIds.add(transferId);
        await _cancelTransfer!(transferId).catchError((_) {});
      }
    }
    await request.directory
        .delete(recursive: true)
        .catchError((_) => request.directory);
  }

  Future<void> _replaceRemoteOffer(_RemoteOffer offer) {
    final cleanup = _removeRemoteOffer(offer.sessionId);
    _remoteOffers[offer.sessionId] = offer;
    _latestRemoteOffer = offer;
    return cleanup;
  }

  Future<void> _removeRemoteOffer(String sessionId) async {
    final removed = _remoteOffers.remove(sessionId);
    if (identical(_latestRemoteOffer, removed)) {
      _latestRemoteOffer = null;
    }
    final request = _incoming.remove(sessionId);
    final transfers = _transferRequests.remove(sessionId);
    // Detach all old state before asynchronous file cleanup can yield to a
    // replacement offer or a local clipboard change.
    final cached = _cached.remove(sessionId);
    _cacheTimers.remove(sessionId)?.cancel();
    request?.complete(RemoteClipboardPasteResult.failed);
    await Future.wait([
      if (request != null) request.dispose(deleteDirectory: true),
      if (transfers != null) _abandonTransferRequest(transfers),
      if (cached != null) cached.dispose(),
    ]);
  }

  Future<void> _removeCached(String sessionId) async {
    _cacheTimers.remove(sessionId)?.cancel();
    await _cached.remove(sessionId)?.dispose();
  }

  bool ownsClipboardPaths(String sessionId, List<String> paths) {
    final cached = _cached[sessionId];
    if (cached == null || paths.length != cached.paths.length) {
      return false;
    }
    for (var index = 0; index < paths.length; index++) {
      if (p.normalize(paths[index]) != p.normalize(cached.paths[index])) {
        return false;
      }
    }
    return true;
  }

  Map<String, dynamic> _frameJson(WhisperFrameV3 frame) {
    if (frame.payload.length > 64 * 1024) {
      throw const FormatException('remote clipboard control too large');
    }
    final decoded = jsonDecode(utf8.decode(frame.payload));
    if (decoded is! Map) {
      throw const FormatException('invalid remote clipboard control');
    }
    return Map<String, dynamic>.from(decoded);
  }

  static Uint8List _jsonBytes(Map<String, Object?> value) {
    return Uint8List.fromList(utf8.encode(jsonEncode(value)));
  }

  static bool _isSafeName(String value) {
    return value.isNotEmpty &&
        value.length <= 255 &&
        value != '.' &&
        value != '..' &&
        p.basename(value) == value &&
        !value.contains('\u0000');
  }

  static Future<Directory> _defaultDirectory() async => Directory.systemTemp;
}

final class _SourceOffer {
  const _SourceOffer({
    required this.offerId,
    required this.sessionId,
    required this.peerId,
    required this.items,
  });

  final String offerId;
  final String sessionId;
  final String peerId;
  final List<RemoteClipboardLocalItem> items;
}

final class _RemoteOffer {
  const _RemoteOffer({
    required this.offerId,
    required this.sessionId,
    required this.peerId,
    required this.items,
    this.viaTransfer = false,
  });

  final String offerId;
  final String sessionId;
  final String peerId;
  final List<_RemoteItem> items;

  /// The source sends these as file transfers when asked with their ids.
  final bool viaTransfer;
  int get totalSize => items.fold<int>(0, (sum, item) => sum + item.size);
}

final class _RemoteItem {
  const _RemoteItem({
    required this.name,
    required this.size,
    required this.isImage,
  });

  final String name;
  final int size;
  final bool isImage;
}

final class _IncomingRequest {
  _IncomingRequest._({
    required this.offer,
    required this.directory,
    required this.paths,
    required this.files,
  });

  static Future<_IncomingRequest> create(
    _RemoteOffer offer,
    Directory directory,
  ) async {
    final paths = <String>[];
    final files = <RandomAccessFile>[];
    final usedNames = <String>{};
    try {
      for (final item in offer.items) {
        final name = _uniqueName(item.name, usedNames);
        final path = p.join(directory.path, name);
        paths.add(path);
        files.add(await File(path).open(mode: FileMode.write));
      }
      return _IncomingRequest._(
        offer: offer,
        directory: directory,
        paths: paths,
        files: files,
      );
    } catch (_) {
      await Future.wait(files.map((file) => file.close().catchError((_) {})));
      await directory.delete(recursive: true).catchError((_) => directory);
      rethrow;
    }
  }

  final _RemoteOffer offer;
  final Directory directory;
  final List<String> paths;
  final List<RandomAccessFile> files;
  final Completer<RemoteClipboardPasteResult> completion =
      Completer<RemoteClipboardPasteResult>();
  late final List<int> offsets = List<int>.filled(offer.items.length, 0);
  bool _closed = false;

  Future<void> add(WhisperFrameV3 frame) async {
    final index = frame.sequence;
    if (_closed || index < 0 || index >= offer.items.length) {
      throw const FormatException('invalid remote clipboard item index');
    }
    final expected = offsets[index];
    final item = offer.items[index];
    if (frame.offset != expected ||
        frame.payload.length > item.size - expected) {
      throw const FormatException('invalid remote clipboard offset');
    }
    await files[index].writeFrom(frame.payload);
    offsets[index] += frame.payload.length;
  }

  Future<List<String>> finish() async {
    if (_closed ||
        List<int>.generate(
          offer.items.length,
          (index) => index,
        ).any((index) => offsets[index] != offer.items[index].size)) {
      throw const FormatException('incomplete remote clipboard transfer');
    }
    _closed = true;
    await Future.wait(files.map((file) => file.close()));
    return List<String>.unmodifiable(paths);
  }

  void complete(RemoteClipboardPasteResult result) {
    if (!completion.isCompleted) {
      completion.complete(result);
    }
  }

  Future<void> dispose({required bool deleteDirectory}) async {
    if (!_closed) {
      _closed = true;
      await Future.wait(files.map((file) => file.close().catchError((_) {})));
    }
    if (deleteDirectory && await directory.exists()) {
      await directory.delete(recursive: true).catchError((_) => directory);
    }
  }

  static String _uniqueName(String original, Set<String> used) {
    var candidate = original;
    var suffix = 2;
    final extension = p.extension(original);
    final stem = p.basenameWithoutExtension(original);
    while (!used.add(candidate.toLowerCase())) {
      candidate = '$stem-$suffix$extension';
      suffix++;
    }
    return candidate;
  }
}

final class _CachedPaste {
  const _CachedPaste({
    required this.offerId,
    required this.directory,
    required this.paths,
    required this.createdAt,
    required this.asImage,
  });

  final String offerId;
  final Directory directory;
  final List<String> paths;
  final DateTime createdAt;
  final bool asImage;

  bool isExpired(Duration ttl) => DateTime.now().difference(createdAt) > ttl;

  Future<bool> filesExist() async {
    for (final path in paths) {
      if (!await File(path).exists()) {
        return false;
      }
    }
    return true;
  }

  Future<void> dispose() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true).catchError((_) => directory);
    }
  }
}

/// A paste whose files come as file transfers, one per item.
final class _TransferRequest {
  _TransferRequest({
    required this.offer,
    required this.directory,
    required this.transferIds,
    required void Function(_TransferRequest request) onStalled,
  }) : paths = List<String?>.filled(transferIds.length, null),
       _onStalled = onStalled {
    touch();
  }

  final _RemoteOffer offer;
  final Directory directory;
  final List<String> transferIds;

  /// Where each item landed, in offer order.
  final List<String?> paths;
  final void Function(_TransferRequest request) _onStalled;
  final Completer<RemoteClipboardPasteResult> completion =
      Completer<RemoteClipboardPasteResult>();
  Timer? _stall;

  /// Progress: a large file may take minutes, but not minutes of nothing.
  void touch() {
    if (completion.isCompleted) {
      return;
    }
    _stall?.cancel();
    _stall = Timer(remoteClipboardTransferStallLimit, () => _onStalled(this));
  }

  void stop() {
    _stall?.cancel();
    _stall = null;
  }

  void complete(RemoteClipboardPasteResult result) {
    stop();
    if (!completion.isCompleted) {
      completion.complete(result);
    }
  }
}
