import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show Locale;
import 'package:mime/mime.dart';

import '../l10n/app_localizations.dart';
import 'share_lan.dart';
import 'share_link.dart';
import 'share_names.dart';
import 'share_pages.dart';
import 'share_password.dart';
import 'share_paths.dart';
import 'share_range.dart';
import 'share_rate_limiter.dart';
import 'share_zip.dart';

/// What the server needs from the links' owner.
abstract interface class ShareServerSource {
  /// The enabled link with this (lowercase) route, or null.
  ShareLink? linkForRoute(String route);

  ShareCookieSigner get cookies;

  Future<String> deviceName();

  /// A page of the link was opened; [counted] when it starts a new visit.
  void linkVisited(ShareLink link, {required bool counted});

  void linkDownloaded(ShareLink link);

  void linkServed(ShareLink link, int bytes);

  /// Something of the link was not on disk any more.
  void linkMissing(ShareLink link);
}

/// None of the ports could be opened.
class ShareServerBindException implements Exception {
  const ShareServerBindException(this.ports, this.cause);

  final List<int> ports;
  final Object? cause;

  @override
  String toString() => 'ShareServerBindException($ports, $cause)';
}

/// The HTTP server behind share links. Listens on all IPv4 interfaces,
/// takes connections from the local network only, and serves the links
/// [source] has enabled:
///
/// * `/<route>`: the link's page (one file, a folder, or several items)
/// * `/<route>/f/<path>`: a file (Range, HEAD) or a folder page
/// * `/<route>/zip[/<path>]`: everything, or a folder, as a streamed zip
/// * `POST /<route>/login`: the password form, for links that have one
class ShareServer {
  ShareServer({
    required this.source,
    ShareRateLimiter? limiter,
    DateTime Function()? clock,
    bool Function(InternetAddress address)? allowClient,
    this.resolver = const ShareResolver(),
    this.stallTimeout = const Duration(seconds: 60),
    this.formTimeout = const Duration(seconds: 10),
    this.maxConnections = 32,
    this.maxConnectionsPerClient = 8,
    this.maxVerifications = 4,
    this.maxZipEntries = ShareZipPlan.defaultMaxEntries,
    this.textPreviewLimit = 32 * 1024,
    Future<List<int>?> Function()? touchIcon,
  }) : _touchIcon = touchIcon ?? _appIcon,
       limiter = limiter ?? ShareRateLimiter(clock: clock),
       _clock = clock ?? DateTime.now,
       _allowClient = allowClient ?? isShareLanAddress;

  final ShareServerSource source;
  final ShareRateLimiter limiter;
  final ShareResolver resolver;

  /// A download whose client has not taken a byte for this long is cut.
  final Duration stallTimeout;

  /// The password form must arrive within this.
  final Duration formTimeout;

  /// Open connections, in all and from one client.
  final int maxConnections;
  final int maxConnectionsPerClient;

  /// Password checks running at once (one per client); more are told to
  /// wait rather than queued.
  final int maxVerifications;

  /// A zip of more entries is refused.
  final int maxZipEntries;

  /// How much of a text file its page shows.
  final int textPreviewLimit;

  /// The icon phones use when the page is added to the home screen.
  final Future<List<int>?> Function() _touchIcon;
  List<int>? _touchIconBytes;
  final DateTime Function() _clock;
  final bool Function(InternetAddress address) _allowClient;

  HttpServer? _server;
  ServerSocket? _socket;
  final _transfers = <_Transfer>{};
  final _visits = <String, DateTime>{};
  final _downloads = <String, DateTime>{};
  String? _deviceName;
  DateTime? _deviceNameAt;
  final _verifying = <String>{};

  static const visitWindow = Duration(minutes: 5);
  static const downloadWindow = Duration(seconds: 60);

  int? get port => _server?.port;
  bool get isRunning => _server != null;

  /// Downloads under way.
  int get activeTransfers => _transfers.length;

  /// Listens on the first of [ports] that is free; returns it.
  Future<int> start(List<int> ports) async {
    final running = _server;
    if (running != null) {
      return running.port;
    }
    Object? cause;
    for (final port in ports) {
      try {
        final socket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        final server = HttpServer.listenOn(
          ShareLanServerSocket(
            socket,
            allow: _allowClient,
            maxConnections: maxConnections,
            maxPerClient: maxConnectionsPerClient,
          ),
        );
        server
          ..autoCompress = false
          ..idleTimeout = const Duration(seconds: 30)
          ..serverHeader = null;
        server.defaultResponseHeaders
          ..set('referrer-policy', 'no-referrer')
          ..set('x-frame-options', 'DENY');
        server.listen(
          (request) => unawaited(_onRequest(request)),
          onError: (Object _) {},
        );
        _server = server;
        _socket = socket;
        return socket.port;
      } on SocketException catch (error) {
        cause = error;
      }
    }
    throw ShareServerBindException(ports, cause);
  }

  /// Closes the port and cuts every download.
  Future<void> stop() async {
    final server = _server;
    final socket = _socket;
    _server = null;
    _socket = null;
    for (final transfer in _transfers.toList()) {
      transfer.cancel();
    }
    _transfers.clear();
    // A server made with listenOn leaves its socket open on close.
    await socket?.close();
    await server?.close(force: true);
  }

  /// Cuts the downloads of a link that was turned off or deleted.
  void dropLink(String linkId) {
    for (final transfer in _transfers.toList()) {
      if (transfer.linkId == linkId) {
        transfer.cancel();
      }
    }
  }

  Future<void> _onRequest(HttpRequest request) async {
    final remote = request.connectionInfo?.remoteAddress;
    if (remote == null || !_allowClient(remote)) {
      await _drop(request);
      return;
    }
    final client = shareClientKey(remote);
    SharePages? pages;
    try {
      pages = await _pagesFor(request);
      await _dispatch(request, client, pages);
    } on Object {
      try {
        await _page(
          request,
          HttpStatus.internalServerError,
          (pages ?? await _pagesFor(request)).message(ShareMessage.error),
        );
      } on Object {
        await _drop(request);
      }
    }
  }

  Future<void> _dispatch(
    HttpRequest request,
    String client,
    SharePages pages,
  ) async {
    final method = request.method;
    if (method != 'GET' && method != 'HEAD' && method != 'POST') {
      request.response.headers.set('allow', 'GET, HEAD, POST');
      await _plain(request, HttpStatus.methodNotAllowed, '');
      return;
    }
    if (!shareHostAllowed(request.headers.value('host'))) {
      // A name from somewhere else pointing here (DNS rebinding).
      await _page(
        request,
        HttpStatus.misdirectedRequest,
        pages.message(ShareMessage.notFound),
      );
      return;
    }
    final List<String> segments;
    try {
      segments = shareRequestSegments(request.uri.path);
    } on SharePathException {
      await _page(
        request,
        HttpStatus.badRequest,
        pages.message(ShareMessage.notFound),
      );
      return;
    }
    if (segments.isEmpty) {
      await _page(
        request,
        HttpStatus.notFound,
        pages.message(ShareMessage.notFound),
      );
      return;
    }
    final first = segments.first.toLowerCase();
    if (await _probe(request, first)) {
      return;
    }
    final wait = limiter.blockedFor(client);
    if (wait != null) {
      await _tooMany(request, pages, wait);
      return;
    }
    final link = source.linkForRoute(first);
    if (link == null) {
      // This answer is still the plain one; the requests after it wait.
      limiter.fail(client);
      await _page(
        request,
        HttpStatus.notFound,
        pages.message(ShareMessage.notFound),
      );
      return;
    }
    final rest = segments.sublist(1);
    final root = '/${link.route}/';
    if (rest.length == 1 && rest.first == 'login') {
      if (method == 'POST' && link.hasPassword) {
        await _login(request, client, pages, link);
      } else {
        await _redirect(request, root);
      }
      return;
    }
    if (link.hasPassword && !_authorized(request, link)) {
      if (method != 'POST') {
        _visit(link, client, request);
      }
      final query = request.uri.query;
      await _page(
        request,
        HttpStatus.unauthorized,
        pages.login(
          action: '/${link.route}/login',
          next: query.isEmpty ? request.uri.path : '${request.uri.path}?$query',
        ),
      );
      return;
    }
    if (method == 'POST') {
      request.response.headers.set('allow', 'GET, HEAD');
      await _plain(request, HttpStatus.methodNotAllowed, '');
      return;
    }
    if (rest.isEmpty) {
      await _root(request, client, pages, link);
    } else if (rest.first == 'f') {
      await _entry(request, client, pages, link, rest.sublist(1));
    } else if (rest.first == 'zip') {
      await _zip(request, client, pages, link, rest.sublist(1));
    } else {
      await _page(
        request,
        HttpStatus.notFound,
        pages.message(ShareMessage.missing, backHref: root),
      );
    }
  }

  /// Requests browsers make by themselves; never counted as guesses.
  Future<bool> _probe(HttpRequest request, String first) async {
    if (first == 'robots.txt') {
      await _plain(request, HttpStatus.ok, 'User-agent: *\nDisallow: /\n');
      return true;
    }
    if (first == 'apple-touch-icon.png' ||
        first == 'apple-touch-icon-precomposed.png') {
      final bytes = _touchIconBytes ??= await _touchIcon();
      if (bytes != null) {
        final response = request.response
          ..statusCode = HttpStatus.ok
          ..contentLength = bytes.length;
        response.headers
          ..set('content-type', 'image/png')
          ..set('cache-control', 'public, max-age=86400');
        response.add(bytes);
        await response.close();
        return true;
      }
    }
    if (first == 'favicon.ico' ||
        first == '.well-known' ||
        first.startsWith('apple-touch-icon')) {
      request.response.headers.set('cache-control', 'max-age=86400');
      await _plain(request, HttpStatus.notFound, '');
      return true;
    }
    return false;
  }

  Future<void> _root(
    HttpRequest request,
    String client,
    SharePages pages,
    ShareLink link,
  ) async {
    if (link.isSingleFile) {
      final item = link.items.first;
      final target = await resolver.resolve(link, [item.name]);
      if (target == null || target.isDir) {
        source.linkMissing(link);
        await _page(
          request,
          HttpStatus.notFound,
          pages.message(ShareMessage.missing),
        );
        return;
      }
      _visit(link, client, request);
      await _filePage(request, pages, link, target, crumbs: const []);
      return;
    }
    if (link.isSingleFolder) {
      final target = await resolver.resolve(link, const []);
      if (target == null || !target.isDir) {
        source.linkMissing(link);
        await _page(
          request,
          HttpStatus.notFound,
          pages.message(ShareMessage.missing),
        );
        return;
      }
      _visit(link, client, request);
      await _folder(request, pages, link, target, const []);
      return;
    }
    final listings = await resolver.listItems(link);
    if (listings.length < link.items.length) {
      source.linkMissing(link);
    }
    if (listings.isEmpty) {
      await _page(
        request,
        HttpStatus.notFound,
        pages.message(ShareMessage.missing),
      );
      return;
    }
    _visit(link, client, request);
    await _page(
      request,
      HttpStatus.ok,
      pages.folder(
        title: shareLinkTitle(pages.text, link),
        crumbs: const [],
        rows: _rows(link, const [], listings),
        zipHref: '/${link.route}/zip',
        count: link.name.isNotEmpty,
      ),
    );
  }

  Future<void> _entry(
    HttpRequest request,
    String client,
    SharePages pages,
    ShareLink link,
    List<String> relative,
  ) async {
    final root = '/${link.route}/';
    if (relative.isEmpty) {
      await _redirect(request, root);
      return;
    }
    final target = await resolver.resolve(link, relative);
    if (target == null) {
      if (!link.isSingleFolder && relative.length == 1) {
        source.linkMissing(link);
      }
      await _page(
        request,
        HttpStatus.notFound,
        pages.message(ShareMessage.missing, backHref: root),
      );
      return;
    }
    if (target.isDir) {
      _visit(link, client, request);
      await _folder(request, pages, link, target, relative);
      return;
    }
    if (request.uri.queryParameters['view'] == '1') {
      // The file's own page, opened from its folder.
      _visit(link, client, request);
      final parent = relative.sublist(0, relative.length - 1);
      final (previous, next, position) = await _neighbours(link, relative);
      await _filePage(
        request,
        pages,
        link,
        target,
        crumbs: _crumbsTo(link, pages, parent),
        previous: previous,
        next: next,
        position: position,
      );
      return;
    }
    await _file(request, client, link, target);
  }

  /// The way from the link's first page down to the folder at [folder]
  /// (that folder included).
  List<(String, String)> _crumbsTo(
    ShareLink link,
    SharePages pages,
    List<String> folder,
  ) {
    final rootLabel = link.isSingleFolder
        ? link.items.first.name
        : shareLinkTitle(pages.text, link);
    return [
      (rootLabel, '/${link.route}/'),
      for (var i = 0; i < folder.length; i++)
        (folder[i], '${_fileHref(link, folder.sublist(0, i + 1))}/'),
    ];
  }

  /// The files before and after [relative] in its folder, as their pages,
  /// and where it is among them.
  Future<(String?, String?, (int, int)?)> _neighbours(
    ShareLink link,
    List<String> relative,
  ) async {
    final parent = relative.sublist(0, relative.length - 1);
    final List<ShareListing> listings;
    if (parent.isEmpty && !link.isSingleFolder) {
      listings = await resolver.listItems(link);
    } else {
      final folder = await resolver.resolve(link, parent);
      if (folder == null || !folder.isDir) {
        return (null, null, null);
      }
      listings = await resolver.list(folder);
    }
    final files = listings.where((listing) => !listing.isDir).toList();
    final index = files.indexWhere((file) => file.name == relative.last);
    if (index < 0) {
      return (null, null, null);
    }
    String page(ShareListing file) =>
        '${_fileHref(link, [...parent, file.name])}?view=1';
    return (
      index > 0 ? page(files[index - 1]) : null,
      index < files.length - 1 ? page(files[index + 1]) : null,
      (index + 1, files.length),
    );
  }

  Future<void> _filePage(
    HttpRequest request,
    SharePages pages,
    ShareLink link,
    ShareTarget target, {
    required List<(String, String)> crumbs,
    String? previous,
    String? next,
    (int, int)? position,
  }) async {
    final href = _fileHref(link, target.relative);
    final snippet = shareShowsText(target.name) && target.size > 0
        ? await shareTextSnippet(target.realPath, limit: textPreviewLimit)
        : null;
    await _page(
      request,
      HttpStatus.ok,
      pages.file(
        ShareFileView(
          name: target.name,
          size: target.size,
          modified: target.modified,
          downloadHref: '$href?dl=1',
          openHref: href,
          previewHref: '$href?preview=1',
          crumbs: crumbs,
          previousHref: previous,
          nextHref: next,
          position: position,
          textPreview: snippet?.$1,
          textTruncated: snippet?.$2 ?? false,
          textLimit: textPreviewLimit,
        ),
      ),
    );
  }

  Future<void> _folder(
    HttpRequest request,
    SharePages pages,
    ShareLink link,
    ShareTarget target,
    List<String> relative,
  ) async {
    final listings = await resolver.list(target);
    final rootLabel = link.isSingleFolder
        ? link.items.first.name
        : shareLinkTitle(pages.text, link);
    await _page(
      request,
      HttpStatus.ok,
      pages.folder(
        title: relative.isEmpty ? rootLabel : relative.last,
        crumbs: relative.isEmpty
            ? const []
            : _crumbsTo(link, pages, relative.sublist(0, relative.length - 1)),
        rows: _rows(link, relative, listings),
        zipHref: relative.isEmpty
            ? '/${link.route}/zip'
            : '/${link.route}/zip/${_encode(relative)}',
      ),
    );
  }

  List<ShareRow> _rows(
    ShareLink link,
    List<String> relative,
    List<ShareListing> listings,
  ) {
    final rows = <ShareRow>[];
    for (final listing in listings) {
      final href = _fileHref(link, [...relative, listing.name]);
      rows.add(
        ShareRow(
          name: listing.name,
          isDir: listing.isDir,
          size: listing.size,
          modified: listing.modified,
          // A file opens its own page (preview, download, next/previous).
          href: listing.isDir ? '$href/' : '$href?view=1',
          downloadHref: '$href?dl=1',
        ),
      );
    }
    return rows;
  }

  Future<void> _file(
    HttpRequest request,
    String client,
    ShareLink link,
    ShareTarget target,
  ) async {
    final response = request.response;
    final query = request.uri.queryParameters;
    final wantsDownload = query['dl'] == '1';
    final isPreview = query['preview'] == '1';
    final name = target.name;
    final size = target.size;
    final modified = target.modified;
    final etag =
        '"${size.toRadixString(36)}-${modified.millisecondsSinceEpoch.toRadixString(36)}"';
    final mime = _mimeOf(name);
    final active = _isActive(mime, name);
    final inline = !wantsDownload && !active && sharePreviewOf(name) != null;
    final headers = response.headers
      ..set('content-type', _contentType(mime))
      ..set('accept-ranges', 'bytes')
      ..set('etag', etag)
      ..set('last-modified', HttpDate.format(modified))
      ..set('cache-control', 'private, no-cache')
      ..set(
        'content-disposition',
        shareContentDisposition(name, inline: inline),
      );
    if (active) {
      // Never let a shared page or picture run script on this origin.
      headers.set('content-security-policy', "sandbox; default-src 'none'");
    }
    if (_notModified(request, etag, modified)) {
      response
        ..statusCode = HttpStatus.notModified
        ..contentLength = 0;
      await response.close();
      return;
    }
    var range = parseShareRange(request.headers.value('range'), size);
    final ifRange = request.headers.value('if-range');
    if (ifRange != null && !_ifRangeMatches(ifRange, etag, modified)) {
      range = const ShareRangeWhole();
    }
    final int start;
    final int end;
    switch (range) {
      case ShareRangeWhole():
        response.statusCode = HttpStatus.ok;
        response.contentLength = size;
        start = 0;
        end = size - 1;
      case ShareRangePart(start: final from, end: final to):
        response.statusCode = HttpStatus.partialContent;
        headers.set('content-range', 'bytes $from-$to/$size');
        response.contentLength = to - from + 1;
        start = from;
        end = to;
      case ShareRangeUnsatisfiable():
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        headers.set('content-range', 'bytes */$size');
        response.contentLength = 0;
        await response.close();
        return;
    }
    if (request.method == 'HEAD' || size == 0) {
      await response.close();
      return;
    }
    if (!isPreview) {
      _download(link, client, target.relative.join('/'), start);
    }
    await _stream(
      request,
      link,
      File(target.realPath).openRead(start, end + 1),
    );
  }

  Future<void> _zip(
    HttpRequest request,
    String client,
    SharePages pages,
    ShareLink link,
    List<String> relative,
  ) async {
    final root = '/${link.route}/';
    ShareTarget? target;
    if (relative.isNotEmpty) {
      target = await resolver.resolve(link, relative);
      if (target == null || !target.isDir) {
        await _page(
          request,
          HttpStatus.notFound,
          pages.message(ShareMessage.missing, backHref: root),
        );
        return;
      }
    }
    final ShareZipPlan plan;
    try {
      plan = await ShareZipPlan.plan(
        resolver.zipSource(link, target: target),
        maxEntries: maxZipEntries,
      );
    } on ShareZipTooLargeException {
      await _page(
        request,
        HttpStatus.requestEntityTooLarge,
        pages.message(ShareMessage.error, backHref: root),
      );
      return;
    }
    if (plan.count == 0) {
      source.linkMissing(link);
      await _page(
        request,
        HttpStatus.notFound,
        pages.message(ShareMessage.missing, backHref: root),
      );
      return;
    }
    final base = target != null
        ? target.name
        : link.isSingleFolder
        ? link.items.first.name
        : shareLinkTitle(pages.text, link);
    final response = request.response
      ..statusCode = HttpStatus.ok
      ..contentLength = plan.length;
    response.headers
      ..set('content-type', 'application/zip')
      ..set('cache-control', 'no-store')
      ..set('content-disposition', shareContentDisposition('$base.zip'));
    if (request.method == 'HEAD') {
      await response.close();
      return;
    }
    _download(link, client, 'zip:${relative.join('/')}', 0);
    await _stream(request, link, plan.stream());
  }

  /// Writes the body straight to the connection, which is then closed, so
  /// a download can be cut off at any moment (link turned off, server
  /// stopped, client stalled).
  Future<void> _stream(
    HttpRequest request,
    ShareLink link,
    Stream<List<int>> body,
  ) async {
    final response = request.response..persistentConnection = false;
    final socket = await response.detachSocket();
    final transfer = _Transfer(link.id, socket);
    _transfers.add(transfer);
    final watchdog = Timer.periodic(stallTimeout ~/ 4, (_) {
      if (transfer.checkStalled()) {
        transfer.cancel();
      }
    });
    try {
      await socket.addStream(
        body.map((chunk) {
          if (transfer.cancelled) {
            throw const _Cancelled();
          }
          transfer.progress += chunk.length;
          source.linkServed(link, chunk.length);
          return chunk;
        }),
      );
      await socket.flush();
      await socket.close();
    } on Object {
      // The client went away, the link was turned off, or a file changed
      // under a zip: the connection is cut and the browser shows it.
    } finally {
      watchdog.cancel();
      _transfers.remove(transfer);
      socket.destroy();
    }
  }

  Future<void> _login(
    HttpRequest request,
    String client,
    SharePages pages,
    ShareLink link,
  ) async {
    final root = '/${link.route}/';
    final form = await _readForm(request);
    if (form == null) {
      // Too slow or too big to be the password form.
      request.response.persistentConnection = false;
      await _plain(request, HttpStatus.requestTimeout, '');
      return;
    }
    final next = _safeNext(link, form['next']);
    final password = form['password'] ?? '';
    final hash = link.password!;
    // One check per client and a few in all, never a queue: PBKDF2 is slow
    // on purpose and a burst of guesses must not pile up behind it.
    if (_verifying.contains(client) || _verifying.length >= maxVerifications) {
      await _tooMany(request, pages, const Duration(seconds: 1));
      return;
    }
    // Counted before the check, so guesses sent in parallel cannot all get
    // past the limiter while it runs.
    if (!limiter.attempt(client)) {
      await _tooMany(
        request,
        pages,
        limiter.blockedFor(client) ?? limiter.backOff,
      );
      return;
    }
    _verifying.add(client);
    bool ok;
    try {
      ok = password.isNotEmpty && await hash.verify(password);
    } finally {
      _verifying.remove(client);
    }
    if (!ok) {
      await _page(
        request,
        HttpStatus.unauthorized,
        pages.login(action: '${root}login', next: next, wrong: true),
      );
      return;
    }
    limiter.succeed(client);
    final token = source.cookies.issue(
      linkId: link.id,
      salt: hash.salt,
      now: _clock(),
    );
    final cookie = Cookie(ShareCookieSigner.cookieName(link.id), token)
      ..httpOnly = true
      ..path = '/${link.route}'
      ..maxAge = ShareCookieSigner.lifetime.inSeconds
      ..sameSite = SameSite.lax;
    request.response.cookies.add(cookie);
    await _redirect(request, next);
  }

  bool _authorized(HttpRequest request, ShareLink link) {
    final name = ShareCookieSigner.cookieName(link.id);
    final token = shareCookieValue(request.headers['cookie'], name);
    return source.cookies.verify(
      linkId: link.id,
      salt: link.password!.salt,
      token: token,
      now: _clock(),
    );
  }

  String _safeNext(ShareLink link, String? next) {
    final root = '/${link.route}/';
    if (next == null ||
        next.length > 2048 ||
        next.contains('\\') ||
        next.contains('//') ||
        next.codeUnits.any((unit) => unit < 0x21 || unit > 0x7e)) {
      return root;
    }
    if (next == '/${link.route}' || next.startsWith(root)) {
      return next;
    }
    return root;
  }

  /// The password form's fields; null when it is larger than a form or
  /// has not fully arrived within [formTimeout].
  Future<Map<String, String>?> _readForm(HttpRequest request) async {
    final type = request.headers.contentType;
    if (type == null || type.mimeType != 'application/x-www-form-urlencoded') {
      return const {};
    }
    const limit = 8192;
    if (request.contentLength > limit) {
      return null;
    }
    final done = Completer<List<int>?>();
    final bytes = BytesBuilder(copy: false);
    late final StreamSubscription<List<int>> subscription;
    void finish(List<int>? value) {
      if (!done.isCompleted) {
        done.complete(value);
      }
    }

    // Paused rather than cancelled when it is given up on: cancelling
    // the body tears the connection down before the answer goes out.
    final deadline = Timer(formTimeout, () {
      subscription.pause();
      finish(null);
    });
    subscription = request.listen(
      (chunk) {
        if (done.isCompleted) {
          return;
        }
        bytes.add(chunk);
        if (bytes.length > limit) {
          subscription.pause();
          finish(null);
        }
      },
      onDone: () => finish(bytes.takeBytes()),
      onError: (Object _) => finish(null),
      cancelOnError: true,
    );
    final body = await done.future;
    deadline.cancel();
    if (body == null) {
      return null;
    }
    try {
      return Uri.splitQueryString(utf8.decode(body));
    } on FormatException {
      return const {};
    }
  }

  void _visit(ShareLink link, String client, HttpRequest request) {
    if (request.method != 'GET') {
      return;
    }
    final now = _clock();
    final key = '${link.id}|$client';
    final last = _visits[key];
    final counted = last == null || now.difference(last) >= visitWindow;
    _visits[key] = now;
    _trim(_visits, visitWindow, now);
    source.linkVisited(link, counted: counted);
  }

  void _download(ShareLink link, String client, String path, int start) {
    if (start != 0) {
      // Resuming or seeking within something already counted.
      return;
    }
    final now = _clock();
    final key = '${link.id}|$client|$path';
    final last = _downloads[key];
    _downloads[key] = now;
    _trim(_downloads, downloadWindow, now);
    if (last == null || now.difference(last) >= downloadWindow) {
      source.linkDownloaded(link);
    }
  }

  void _trim(Map<String, DateTime> seen, Duration window, DateTime now) {
    if (seen.length > 2048) {
      seen.removeWhere((_, at) => now.difference(at) >= window);
    }
  }

  Future<SharePages> _pagesFor(HttpRequest request) async {
    final locale = shareLocaleFor(request.headers.value('accept-language'));
    return SharePages(
      text: lookupAppLocalizations(locale),
      languageTag: locale.languageCode == 'zh'
          ? 'zh-Hans'
          : locale.languageCode,
      deviceName: await _device(),
      devicePlatform: Platform.operatingSystem,
      now: _clock(),
    );
  }

  Future<String> _device() async {
    final now = _clock();
    final cached = _deviceName;
    final at = _deviceNameAt;
    if (cached != null && at != null && now.difference(at).inSeconds < 30) {
      return cached;
    }
    String name;
    try {
      name = await source.deviceName();
    } on Object {
      name = cached ?? Platform.localHostname;
    }
    _deviceName = name;
    _deviceNameAt = now;
    return name;
  }

  Future<void> _page(HttpRequest request, int status, String html) async {
    final response = request.response..statusCode = status;
    response.headers
      ..set('content-type', 'text/html; charset=utf-8')
      ..set('cache-control', 'no-store')
      ..set('content-security-policy', _pagePolicy)
      ..set('vary', 'accept-language, cookie');
    final bytes = utf8.encode(html);
    response.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }

  Future<void> _plain(HttpRequest request, int status, String body) async {
    final response = request.response..statusCode = status;
    response.headers.set('content-type', 'text/plain; charset=utf-8');
    final bytes = utf8.encode(body);
    response.contentLength = bytes.length;
    response.add(bytes);
    await response.close();
  }

  Future<void> _redirect(HttpRequest request, String location) async {
    final response = request.response
      ..statusCode = HttpStatus.seeOther
      ..contentLength = 0;
    response.headers
      ..set('location', location)
      ..set('cache-control', 'no-store');
    await response.close();
  }

  Future<void> _tooMany(
    HttpRequest request,
    SharePages pages,
    Duration wait,
  ) async {
    request.response.headers.set(
      'retry-after',
      '${wait.inSeconds < 1 ? 1 : wait.inSeconds}',
    );
    await _page(
      request,
      HttpStatus.tooManyRequests,
      pages.message(ShareMessage.tooMany),
    );
  }

  Future<void> _drop(HttpRequest request) async {
    try {
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.destroy();
    } on Object {
      // Already answered or gone.
    }
  }

  bool _notModified(HttpRequest request, String etag, DateTime modified) {
    final match = request.headers.value('if-none-match');
    if (match != null) {
      return match
          .split(',')
          .map((tag) => tag.trim())
          .any((tag) => tag == '*' || tag == etag || tag == 'W/$etag');
    }
    final since = request.headers.ifModifiedSince;
    if (since != null) {
      return modified.millisecondsSinceEpoch ~/ 1000 <=
          since.millisecondsSinceEpoch ~/ 1000;
    }
    return false;
  }

  bool _ifRangeMatches(String value, String etag, DateTime modified) {
    final trimmed = value.trim();
    if (trimmed.startsWith('"') || trimmed.startsWith('W/')) {
      return trimmed == etag;
    }
    try {
      final date = HttpDate.parse(trimmed);
      return modified.millisecondsSinceEpoch ~/ 1000 ==
          date.millisecondsSinceEpoch ~/ 1000;
    } on HttpException {
      return false;
    }
  }

  String _fileHref(ShareLink link, List<String> relative) =>
      '/${link.route}/f/${_encode(relative)}';

  String _encode(List<String> segments) =>
      segments.map(Uri.encodeComponent).join('/');
}

const _pagePolicy =
    "default-src 'none'; img-src 'self' data:; media-src 'self'; "
    "style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; "
    "frame-ancestors 'none'";

String _mimeOf(String name) =>
    lookupMimeType(name.toLowerCase()) ?? 'application/octet-stream';

/// Types a browser would run script in when opened directly.
bool _isActive(String mime, String name) {
  final lower = mime.toLowerCase();
  return lower.contains('html') ||
      lower.contains('xml') ||
      lower.contains('svg') ||
      lower.contains('javascript') ||
      lower.contains('ecmascript') ||
      name.toLowerCase().endsWith('.svgz');
}

String _contentType(String mime) {
  if (mime.startsWith('text/') ||
      mime == 'application/json' ||
      mime == 'application/javascript') {
    return '$mime; charset=utf-8';
  }
  return mime;
}

/// `attachment` (or `inline`) with an ASCII fallback name and the real one
/// in RFC 5987 form, so every browser saves it under its own name.
String shareContentDisposition(String name, {bool inline = false}) {
  final fallback = StringBuffer();
  for (final rune in name.runes) {
    final ok =
        rune >= 0x20 &&
        rune < 0x7f &&
        rune != 0x22 &&
        rune != 0x5c &&
        rune != 0x25;
    fallback.writeCharCode(ok ? rune : 0x5f);
  }
  final encoded = StringBuffer();
  for (final byte in utf8.encode(name)) {
    final c = String.fromCharCode(byte);
    final unreserved = RegExp(r"[A-Za-z0-9!#$&+.^_`|~-]").hasMatch(c);
    encoded.write(
      unreserved
          ? c
          : '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}',
    );
  }
  return '${inline ? 'inline' : 'attachment'}; filename="$fallback"; '
      "filename*=UTF-8''$encoded";
}

/// Whether a request's `Host` names this device the way a LAN visitor
/// would: an address, `localhost`, a single-label or `.local` / `.lan` /
/// `.home.arpa` name. A public name that resolves here is a web page
/// trying to read the LAN through someone's browser.
bool shareHostAllowed(String? header) {
  if (header == null || header.isEmpty) {
    return true;
  }
  var host = header.trim().toLowerCase();
  if (host.startsWith('[')) {
    final end = host.indexOf(']');
    return end > 0 && InternetAddress.tryParse(host.substring(1, end)) != null;
  }
  final colon = host.lastIndexOf(':');
  if (colon >= 0) {
    host = host.substring(0, colon);
  }
  if (host.endsWith('.')) {
    host = host.substring(0, host.length - 1);
  }
  if (InternetAddress.tryParse(host) != null) {
    return true;
  }
  return host == 'localhost' ||
      !host.contains('.') ||
      host.endsWith('.local') ||
      host.endsWith('.lan') ||
      host.endsWith('.home.arpa') ||
      host.endsWith('.localdomain');
}

/// The value of cookie [name] in `Cookie` request headers, read leniently.
String? shareCookieValue(List<String>? headers, String name) {
  if (headers == null) {
    return null;
  }
  for (final header in headers) {
    for (final part in header.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      if (part.substring(0, eq).trim() == name) {
        var value = part.substring(eq + 1).trim();
        if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
          value = value.substring(1, value.length - 1);
        }
        return value;
      }
    }
  }
  return null;
}

/// The page language for an `Accept-Language` header: the most wanted of
/// Chinese, English and Spanish, else English.
Locale shareLocaleFor(String? header) {
  if (header == null || header.trim().isEmpty) {
    return const Locale('en');
  }
  final options = <(String, double, int)>[];
  var index = 0;
  for (final part in header.split(',')) {
    final pieces = part.trim().split(';');
    final tag = pieces.first.trim().toLowerCase();
    var quality = 1.0;
    for (final parameter in pieces.skip(1)) {
      final trimmed = parameter.trim();
      if (trimmed.startsWith('q=')) {
        quality = double.tryParse(trimmed.substring(2)) ?? 0;
      }
    }
    if (tag.isNotEmpty && quality > 0) {
      options.add((tag, quality, index++));
    }
  }
  options.sort((a, b) {
    final byQuality = b.$2.compareTo(a.$2);
    return byQuality != 0 ? byQuality : a.$3.compareTo(b.$3);
  });
  for (final (tag, _, _) in options) {
    final language = tag.split('-').first;
    if (language == 'zh' || language == 'en' || language == 'es') {
      return Locale(language);
    }
  }
  return const Locale('en');
}

class _Transfer {
  _Transfer(this.linkId, this.socket);

  final String linkId;
  final Socket socket;
  bool cancelled = false;
  int progress = 0;
  int _seen = -1;
  int _quiet = 0;

  /// True after four checks in a row without progress.
  bool checkStalled() {
    if (progress != _seen) {
      _seen = progress;
      _quiet = 0;
      return false;
    }
    return ++_quiet >= 4;
  }

  void cancel() {
    cancelled = true;
    socket.destroy();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// The app's icon from its assets, or null when it cannot be read (tests
/// without the asset bundle).
Future<List<int>?> _appIcon() async {
  try {
    final data = await rootBundle.load('assets/app_icon_round.png');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } on Object {
    return null;
  }
}

/// The start of a text file for its page: up to [limit] bytes decoded as
/// UTF-8, and whether there was more. Null for anything that looks binary
/// (a NUL early on) or cannot be read.
Future<(String, bool)?> shareTextSnippet(
  String path, {
  int limit = 32768,
}) async {
  RandomAccessFile? file;
  try {
    file = await File(path).open();
    final bytes = await file.read(limit + 1);
    final probe = bytes.length < 8192 ? bytes.length : 8192;
    for (var i = 0; i < probe; i++) {
      if (bytes[i] == 0) {
        return null;
      }
    }
    final truncated = bytes.length > limit;
    var text = utf8.decode(
      truncated ? bytes.sublist(0, limit) : bytes,
      allowMalformed: true,
    );
    if (text.startsWith('\uFEFF')) {
      text = text.substring(1);
    }
    if (truncated) {
      // A character cut in two at the end decodes as U+FFFD.
      while (text.endsWith('\uFFFD')) {
        text = text.substring(0, text.length - 1);
      }
    }
    return (text, truncated);
  } on FileSystemException {
    return null;
  } finally {
    await file?.close();
  }
}
