import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/share_links/share_range.dart';
import 'package:whisper/share_links/share_server.dart';
import 'package:whisper/socket/file_transfer_source.dart';

import 'web_transfer_coordinator.dart';
import 'web_transfer_protocol.dart';
import 'web_transfer_session.dart';
import 'web_transfer_uploads.dart';

/// Web transfer's part of the share link server: `/` is the page, and
/// `/w/...` what it talks to. See docs/internals/web-transfer.md「协议」.
class WebTransferRoutes implements ShareServerExtension {
  WebTransferRoutes(this._coordinator, {Future<String> Function()? loadPage})
    : _loadPage = loadPage ?? _assetPage;

  final WebTransferCoordinator _coordinator;
  final Future<String> Function() _loadPage;
  _Page? _page;

  static const _bootOpen = '<script id="boot" type="application/json">';

  /// Shown inline when the page asks to preview them; everything else is a
  /// download.
  static const _viewable = {
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'image/heic',
    'image/heif',
    'image/avif',
    'video/mp4',
    'video/quicktime',
    'video/webm',
  };

  @override
  Future<bool> handle(
    HttpRequest request,
    List<String> segments,
    String client,
  ) async {
    if (segments.isNotEmpty && segments.first != 'w') {
      return false;
    }
    try {
      switch (segments) {
        case []:
          await _servePage(request);
        case ['w', 'ws']:
          await _socket(request, client);
        case ['w', 'session']:
          await _session(request);
        case ['w', 'up', final id]:
          await _upload(request, id);
        case ['w', 'f', final id]:
          await _file(request, id);
        default:
          await _status(request, HttpStatus.notFound);
      }
    } on Object {
      try {
        await _status(request, HttpStatus.internalServerError);
      } on Object {
        // Already answered, or the socket was handed over.
      }
    }
    return true;
  }

  Future<void> _servePage(HttpRequest request) async {
    if (!_allow(request, const ['GET', 'HEAD'])) {
      return;
    }
    final page = _page ??= _Page.parse(await _loadPage());
    final looks = await _coordinator.hostLooks();
    // The page reads it as JSON; `<` would let a name end the script block.
    final boot = jsonEncode({'host': looks}).replaceAll('<', r'<');
    final bytes = utf8.encode('${page.before}$boot${page.after}');
    final host = request.headers.value('host') ?? '';
    final socketSource = RegExp(r'^[A-Za-z0-9.:\[\]-]+$').hasMatch(host)
        ? ' ws://$host'
        : '';
    final response = request.response..statusCode = HttpStatus.ok;
    response.headers
      ..set('content-type', 'text/html; charset=utf-8')
      ..set('cache-control', 'no-store')
      ..set('x-content-type-options', 'nosniff')
      ..set(
        'content-security-policy',
        "default-src 'none'; script-src ${page.scripts}; "
            "style-src ${page.styles}; img-src 'self' blob: data:; "
            "media-src 'self' blob:; connect-src 'self'$socketSource; "
            "base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      );
    response.contentLength = bytes.length;
    if (request.method != 'HEAD') {
      response.add(bytes);
    }
    await response.close();
  }

  Future<void> _socket(HttpRequest request, String client) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      await _status(request, HttpStatus.badRequest);
      return;
    }
    if (!_sameOrigin(request)) {
      await _status(request, HttpStatus.forbidden);
      return;
    }
    // No permessage-deflate: inflating happens before any size check, so a
    // small compressed message could unpack into memory without bound.
    final socket = await WebSocketTransformer.upgrade(
      request,
      compression: CompressionOptions.compressionOff,
    );
    _coordinator.accept(socket, client);
  }

  /// Turns the session the page was given into an HttpOnly cookie, which its
  /// downloads, previews and uploads then carry.
  Future<void> _session(HttpRequest request) async {
    if (!_allow(request, const ['POST'])) {
      return;
    }
    if (!_sameOrigin(request)) {
      await _drain(request);
      await _status(request, HttpStatus.forbidden);
      return;
    }
    final body = await _smallBody(request);
    Object? token;
    try {
      final decoded = body == null ? null : jsonDecode(body);
      token = decoded is Map ? decoded['token'] : null;
    } on FormatException {
      token = null;
    }
    final session = _coordinator.sessionFor(token is String ? token : null);
    if (session == null) {
      await _status(request, HttpStatus.forbidden);
      return;
    }
    request.response.headers.add(
      'set-cookie',
      '$webSessionCookie=${session.token}; Path=/; HttpOnly; SameSite=Strict',
    );
    await _status(request, HttpStatus.noContent);
  }

  Future<void> _upload(HttpRequest request, String id) async {
    if (!_allow(request, const ['GET', 'PUT'])) {
      return;
    }
    final session = _visit(request);
    final upload = session?.uploads[id];
    if (request.method == 'GET') {
      if (upload == null) {
        await _status(request, HttpStatus.notFound);
      } else {
        await _status(request, HttpStatus.ok, {'committed': upload.committed});
      }
      return;
    }
    if (!_sameOrigin(request) || session == null || upload == null) {
      await _drain(request);
      await _status(
        request,
        upload == null && session != null
            ? HttpStatus.notFound
            : HttpStatus.forbidden,
      );
      return;
    }
    final range = parseWebContentRange(request.headers.value('content-range'));
    final length = range == null ? -1 : range.end - range.start + 1;
    if (range == null ||
        range.total != upload.offer.size ||
        length > webMaxChunkBytes ||
        (request.contentLength >= 0 && request.contentLength != length)) {
      await _drain(request);
      await _status(request, HttpStatus.badRequest, {'error': 'range'});
      return;
    }
    if (range.start != upload.committed || upload.busy) {
      await _drain(request);
      await _status(request, HttpStatus.conflict, {
        'committed': upload.committed,
      });
      return;
    }
    try {
      await upload.write(
        range.start,
        length,
        request.map((chunk) {
          _coordinator.records.uploading(session, upload);
          return chunk;
        }),
      );
    } on WebChunkException catch (error) {
      switch (error.reason) {
        case WebChunkRefusal.position:
          await _drain(request);
          await _status(request, HttpStatus.conflict, {
            'committed': upload.committed,
          });
        case WebChunkRefusal.space:
          await _coordinator.refuseUpload(session, upload);
          await _status(request, HttpStatus.insufficientStorage, {
            'error': 'space',
          });
        case WebChunkRefusal.size || WebChunkRefusal.failed:
          await _coordinator.chunkDone(session, upload);
          await _status(request, HttpStatus.badRequest, {'error': 'failed'});
      }
      return;
    } on Object {
      // The body broke off: what arrived stays, and the page asks where to
      // go on from.
      await _coordinator.chunkDone(session, upload);
      return;
    }
    await _status(request, HttpStatus.ok, {'committed': upload.committed});
    await _coordinator.chunkDone(session, upload);
  }

  Future<void> _file(HttpRequest request, String id) async {
    if (!_allow(request, const ['GET', 'HEAD'])) {
      return;
    }
    final session = _visit(request);
    final message = session == null
        ? null
        : await _coordinator.records.outgoing(session, id);
    final source = message == null ? null : await _sourceOf(message);
    if (session == null || message == null || source == null) {
      await _status(
        request,
        session == null ? HttpStatus.forbidden : HttpStatus.notFound,
      );
      return;
    }
    final (size, modified, read) = source;
    final response = request.response;
    final mime = shareMimeOf(message.name);
    final preview = request.uri.queryParameters['view'] == '1';
    final inline = preview && _viewable.contains(mime);
    final etag =
        '"${size.toRadixString(36)}-${modified.millisecondsSinceEpoch.toRadixString(36)}"';
    response.headers
      ..set('content-type', inline ? mime : shareContentType(mime))
      ..set('accept-ranges', 'bytes')
      ..set('etag', etag)
      ..set('last-modified', HttpDate.format(modified))
      ..set('cache-control', 'private, no-cache')
      ..set('x-content-type-options', 'nosniff')
      ..set('content-security-policy', "sandbox; default-src 'none'")
      ..set(
        'content-disposition',
        shareContentDisposition(message.name, inline: inline),
      );
    if (shareNotModified(request, etag, modified)) {
      response
        ..statusCode = HttpStatus.notModified
        ..contentLength = 0;
      await response.close();
      return;
    }
    var range = parseShareRange(request.headers.value('range'), size);
    final ifRange = request.headers.value('if-range');
    if (ifRange != null && !shareIfRangeMatches(ifRange, etag, modified)) {
      range = const ShareRangeWhole();
    }
    final (start, end) = switch (range) {
      ShareRangeWhole() => (0, size - 1),
      ShareRangePart(start: final from, end: final to) => (from, to),
      ShareRangeUnsatisfiable() => (-1, -1),
    };
    if (start < 0) {
      response
        ..statusCode = HttpStatus.requestedRangeNotSatisfiable
        ..contentLength = 0;
      response.headers.set('content-range', 'bytes */$size');
      await response.close();
      return;
    }
    if (range is ShareRangePart) {
      response.statusCode = HttpStatus.partialContent;
      response.headers.set('content-range', 'bytes $start-$end/$size');
    } else {
      response.statusCode = HttpStatus.ok;
    }
    response.contentLength = end - start + 1;
    if (request.method == 'HEAD' || size == 0) {
      await response.close();
      if (size == 0 && request.method != 'HEAD') {
        await _coordinator.records.served(session, message, end: 0, done: true);
      }
      return;
    }
    response.persistentConnection = false;
    final socket = await response.detachSocket();
    session.downloads.add(socket);
    var sent = start;
    Future<void> paused() async {
      // Previews (a picture in the list, a video's first frame) say nothing
      // until they have all of it.
      if (!preview) {
        await _coordinator.records.update(
          message.uuid,
          state: FileTransferState.waitingReconnect,
          committed: sent,
        );
      }
    }

    try {
      await socket.addStream(
        read(start, end + 1).map((chunk) {
          sent += chunk.length;
          if (!preview) {
            unawaited(
              _coordinator.records.served(
                session,
                message,
                end: sent,
                done: false,
              ),
            );
          }
          return chunk;
        }),
      );
      await socket.flush();
      await socket.close();
      if (sent == size) {
        await _coordinator.records.served(
          session,
          message,
          end: sent,
          done: true,
        );
      } else {
        await paused();
      }
    } on Object {
      await paused();
    } finally {
      session.downloads.remove(socket);
      socket.destroy();
    }
  }

  /// The file's size, time and a reader, or null when it is gone.
  Future<(int, DateTime, Stream<List<int>> Function(int, int))?> _sourceOf(
    MessageData message,
  ) async {
    final path = message.path;
    if (isAndroidContentUri(path)) {
      final source = AndroidContentUriTransferSource(
        uri: path,
        expectedSize: message.size,
      );
      try {
        final size = await source.length();
        return (
          size,
          DateTime.fromMillisecondsSinceEpoch(message.timestamp * 1000),
          (int from, int to) => _readContent(source, from, to),
        );
      } on Object {
        return null;
      }
    }
    final file = File(path);
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        return null;
      }
      return (stat.size, stat.modified, file.openRead);
    } on FileSystemException {
      return null;
    }
  }

  static Stream<List<int>> _readContent(
    AndroidContentUriTransferSource source,
    int from,
    int to,
  ) async* {
    var at = from;
    while (at < to) {
      final want = to - at < 1024 * 1024 ? to - at : 1024 * 1024;
      final bytes = await source.readRange(at, want);
      if (bytes.isEmpty) {
        throw const FileSystemException('content ended early');
      }
      at += bytes.length;
      yield bytes;
    }
  }

  WebSession? _visit(HttpRequest request) => _coordinator.sessionFor(
    shareCookieValue(request.headers['cookie'], webSessionCookie),
  );

  /// A request that changes something must come from the page itself: a
  /// page elsewhere could otherwise use a visitor's browser to send here.
  bool _sameOrigin(HttpRequest request) {
    final origin = request.headers.value('origin');
    final host = request.headers.value('host');
    return origin != null &&
        host != null &&
        origin.toLowerCase() == 'http://${host.toLowerCase()}';
  }

  bool _allow(HttpRequest request, List<String> methods) {
    if (methods.contains(request.method)) {
      return true;
    }
    request.response.headers.set('allow', methods.join(', '));
    unawaited(_status(request, HttpStatus.methodNotAllowed));
    return false;
  }

  /// Reads up to 1 KiB of body within 10 seconds.
  Future<String?> _smallBody(HttpRequest request) async {
    if (request.contentLength > 1024) {
      return null;
    }
    final bytes = <int>[];
    try {
      await for (final chunk in request.timeout(const Duration(seconds: 10))) {
        bytes.addAll(chunk);
        if (bytes.length > 1024) {
          return null;
        }
      }
      return utf8.decode(bytes, allowMalformed: true);
    } on Object {
      return null;
    }
  }

  /// Reads and drops a body that is not wanted, so the answer reaches a page
  /// that is still sending it; a big one closes the connection instead.
  Future<void> _drain(HttpRequest request) async {
    if (request.contentLength > webMaxChunkBytes) {
      request.response.persistentConnection = false;
      return;
    }
    try {
      await request.drain<void>().timeout(const Duration(seconds: 30));
    } on Object {
      request.response.persistentConnection = false;
    }
  }

  Future<void> _status(
    HttpRequest request,
    int status, [
    Map<String, Object?>? body,
  ]) async {
    final response = request.response..statusCode = status;
    response.headers
      ..set('cache-control', 'no-store')
      ..set('x-content-type-options', 'nosniff');
    if (body == null) {
      response.contentLength = 0;
    } else {
      final bytes = utf8.encode(jsonEncode(body));
      response.headers.set('content-type', 'application/json');
      response.contentLength = bytes.length;
      response.add(bytes);
    }
    await response.close();
  }

  static Future<String> _assetPage() =>
      rootBundle.loadString('assets/web_transfer/index.html', cache: false);
}

/// The page split around its boot data, with the hashes of its inline style
/// and script for the Content-Security-Policy.
class _Page {
  const _Page(this.before, this.after, this.scripts, this.styles);

  final String before, after, scripts, styles;

  factory _Page.parse(String source) {
    // A Windows checkout has CRLF. Browsers hash inline blocks after turning
    // line ends into LF, so hashes over CRLF would block the whole page.
    final html = source.replaceAll(RegExp(r'\r\n?'), '\n');
    final open = html.indexOf(WebTransferRoutes._bootOpen);
    if (open < 0) {
      throw const FormatException('the page has no boot block');
    }
    final start = open + WebTransferRoutes._bootOpen.length;
    final end = html.indexOf('</script>', start);
    return _Page(
      html.substring(0, start),
      html.substring(end),
      _hashes(html, RegExp(r'<script>([\s\S]*?)</script>')),
      _hashes(html, RegExp(r'<style>([\s\S]*?)</style>')),
    );
  }

  static String _hashes(String html, RegExp block) => [
    for (final match in block.allMatches(html))
      "'sha256-${base64.encode(sha256.convert(utf8.encode(match.group(1)!)).bytes)}'",
  ].join(' ');
}
