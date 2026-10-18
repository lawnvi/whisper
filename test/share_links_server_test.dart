import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/share_links/share_debug_hooks.dart';
import 'package:whisper/share_links/share_link_store.dart';
import 'package:whisper/share_links/share_password.dart';
import 'package:whisper/share_links/share_rate_limiter.dart';
import 'package:whisper/share_links/share_server.dart';

class _MemoryPreferences implements ShareLinkPreferences {
  final values = <String, Object>{};

  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;

  @override
  Future<int?> getInt(String key) async => values[key] as int?;

  @override
  Future<String?> getString(String key) async => values[key] as String?;

  @override
  Future<void> setBool(String key, bool value) async => values[key] = value;

  @override
  Future<void> setInt(String key, int value) async => values[key] = value;

  @override
  Future<void> setString(String key, String value) async => values[key] = value;
}

class _Reply {
  _Reply(this.status, this.headers, this.body);

  final int status;
  final HttpHeaders headers;
  final List<int> body;

  String get text => utf8.decode(body, allowMalformed: true);
}

final _client = HttpClient()..autoUncompress = false;

Future<_Reply> _send(
  String method,
  Uri url, {
  Map<String, String> headers = const {},
  String? form,
  bool follow = false,
}) async {
  final request = await _client.openUrl(method, url);
  request.followRedirects = follow;
  headers.forEach(request.headers.set);
  if (form != null) {
    request.headers.contentType = ContentType(
      'application',
      'x-www-form-urlencoded',
      charset: 'utf-8',
    );
    request.write(form);
  }
  final response = await request.close();
  final body = <int>[];
  await for (final chunk in response) {
    body.addAll(chunk);
  }
  return _Reply(response.statusCode, response.headers, body);
}

Future<bool> _listening(int port) async {
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 2),
    );
    socket.destroy();
    return true;
  } on SocketException {
    return false;
  }
}

/// A free port with [span] free ports after it, as far as a quick bind can
/// tell.
Future<int> _freeBase(int span) async {
  final rng = Random();
  for (var attempt = 0; attempt < 50; attempt++) {
    final base = 20000 + rng.nextInt(30000);
    var free = true;
    for (var port = base; port <= base + span; port++) {
      try {
        final socket = await ServerSocket.bind(InternetAddress.anyIPv4, port);
        await socket.close();
      } on SocketException {
        free = false;
        break;
      }
    }
    if (free) {
      return base;
    }
  }
  throw StateError('no free ports');
}

void main() {
  late Directory temp;
  late String folder;
  late String movie;
  late List<int> movieBytes;
  late _MemoryPreferences prefs;
  late ShareLinkStore store;
  late int base;
  var now = DateTime(2026, 10, 17, 12);

  ShareLinkStore makeStore({ShareRateLimiter? limiter}) => ShareLinkStore(
    preferences: prefs,
    addresses: () async => ['127.0.0.1'],
    deviceName: () async => 'Test Mac',
    clock: () => now,
    defaultPort: base,
    portSpan: 3,
    flushDelay: const Duration(milliseconds: 50),
    server: (source) => ShareServer(
      source: source,
      clock: () => now,
      limiter: limiter ?? ShareRateLimiter(clock: () => now),
    ),
  );

  Uri url(String path) => Uri.parse('http://127.0.0.1:${store.port}$path');

  /// The store again, with a server made to [server]'s measure.
  Future<void> restartWith(
    ShareServer Function(ShareServerSource source) server,
  ) async {
    await store.shutdown();
    store.dispose();
    store = ShareLinkStore(
      preferences: prefs,
      addresses: () async => ['127.0.0.1'],
      deviceName: () async => 'Test Mac',
      clock: () => now,
      defaultPort: base,
      portSpan: 3,
      server: server,
    );
    await store.initialize();
  }

  setUp(() async {
    now = DateTime(2026, 10, 17, 12);
    temp = await Directory.systemTemp.createTemp('share_server_');
    final root = await temp.resolveSymbolicLinks();
    folder = p.join(root, 'Holiday 2026');
    await Directory(p.join(folder, 'day 1')).create(recursive: true);
    await File(p.join(folder, 'notes.txt')).writeAsString('notes');
    await File(p.join(folder, 'day 1', 'map.pdf')).writeAsBytes([1, 2, 3]);
    movie = p.join(root, '电影.mp4');
    movieBytes = List<int>.generate(300000, (i) => (i * 31) & 0xff);
    await File(movie).writeAsBytes(movieBytes);
    prefs = _MemoryPreferences();
    base = await _freeBase(3);
    store = makeStore();
    await store.initialize();
  });

  tearDown(() async {
    await store.shutdown();
    store.dispose();
    await temp.delete(recursive: true);
  });

  test('the port is open only while the service is on and a link is', () async {
    expect(store.serverState.phase, ShareServerPhase.stopped);
    expect(await _listening(base), isFalse);

    final link = await store.create(paths: [movie]);
    expect(store.serverState.phase, ShareServerPhase.running);
    expect(store.port, base);
    expect(await _listening(base), isTrue);

    await store.setEnabled(link.id, false);
    expect(store.serverState.phase, ShareServerPhase.stopped);
    expect(await _listening(base), isFalse);

    await store.setEnabled(link.id, true);
    expect(await _listening(base), isTrue);

    await store.setServiceOn(false);
    expect(await _listening(base), isFalse);
    expect(store.links.single.enabled, isTrue, reason: 'links are kept');

    await store.setServiceOn(true);
    expect(await _listening(base), isTrue);

    await store.remove(link.id);
    expect(await _listening(base), isFalse);
    expect(store.links, isEmpty);
  });

  test(
    'a taken port moves the server to the next one and remembers it',
    () async {
      final blocker = await ServerSocket.bind(InternetAddress.anyIPv4, base);
      try {
        await store.create(paths: [movie]);
        expect(store.port, base + 1);
        expect(prefs.values[ShareLinkStore.portKey], base + 1);
      } finally {
        await blocker.close();
      }
    },
  );

  test('every port taken is reported, not thrown', () async {
    final blockers = [
      for (var port = base; port <= base + 3; port++)
        await ServerSocket.bind(InternetAddress.anyIPv4, port),
    ];
    try {
      final link = await store.create(paths: [movie]);
      expect(link.route, isNotEmpty);
      expect(store.serverState.phase, ShareServerPhase.failed);
      expect(store.serverState.failure, ShareServerFailure.portsBusy);
    } finally {
      for (final blocker in blockers) {
        await blocker.close();
      }
    }
    await store.retry();
    expect(store.serverState.phase, ShareServerPhase.running);
  });

  test('a single file: page, download, ranges and HEAD', () async {
    final link = await store.create(paths: [movie], route: 'Film-1');
    expect(link.route, 'film-1');
    final page = await _send(
      'GET',
      url('/FILM-1'),
      headers: {'accept-language': 'zh-CN,zh;q=0.9'},
    );
    expect(page.status, 200);
    expect(page.headers.contentType!.mimeType, 'text/html');
    expect(page.text, contains('电影.mp4'));
    expect(page.text, contains('lang="zh-Hans"'));
    expect(page.text, contains('Test Mac'));
    expect(page.text, contains('<video'));
    expect(page.headers.value('content-security-policy'), contains("'none'"));

    final href = '/film-1/f/${Uri.encodeComponent('电影.mp4')}';
    final whole = await _send('GET', url('$href?dl=1'));
    expect(whole.status, 200);
    expect(whole.body, movieBytes);
    expect(whole.headers.value('accept-ranges'), 'bytes');
    expect(whole.headers.contentType!.mimeType, 'video/mp4');
    expect(
      whole.headers.value('content-disposition'),
      allOf(startsWith('attachment;'), contains("UTF-8''%E7%94%B5")),
    );

    final inline = await _send('GET', url(href));
    expect(inline.headers.value('content-disposition'), startsWith('inline;'));

    final tail = await _send(
      'GET',
      url(href),
      headers: {'range': 'bytes=-500'},
    );
    expect(tail.status, 206);
    expect(tail.body, movieBytes.sublist(movieBytes.length - 500));
    expect(
      tail.headers.value('content-range'),
      'bytes ${movieBytes.length - 500}-${movieBytes.length - 1}/${movieBytes.length}',
    );

    final resume = await _send(
      'GET',
      url(href),
      headers: {
        'range': 'bytes=1000-',
        'if-range': whole.headers.value('etag')!,
      },
    );
    expect(resume.status, 206);
    expect(resume.body, movieBytes.sublist(1000));

    final stale = await _send(
      'GET',
      url(href),
      headers: {'range': 'bytes=1000-', 'if-range': '"other"'},
    );
    expect(stale.status, 200);
    expect(stale.body.length, movieBytes.length);

    final bad = await _send(
      'GET',
      url(href),
      headers: {'range': 'bytes=${movieBytes.length}-'},
    );
    expect(bad.status, 416);
    expect(bad.headers.value('content-range'), 'bytes */${movieBytes.length}');

    final head = await _send('HEAD', url(href));
    expect(head.status, 200);
    expect(head.body, isEmpty);
    expect(head.headers.contentLength, movieBytes.length);

    await Future<void>.delayed(const Duration(milliseconds: 120));
    final counted = store.linkById(link.id)!;
    expect(counted.visits, 1);
    // dl=1, the inline open; resumes, tails and HEAD do not count.
    expect(counted.downloads, 1);
    expect(counted.bytesServed, greaterThan(movieBytes.length * 2));
    expect(counted.lastVisitAt, now);
  });

  test('folders: listing, sub-folders, zip, and nothing outside', () async {
    await store.create(paths: [folder], route: 'trip');
    final page = await _send('GET', url('/trip/'));
    expect(page.status, 200);
    expect(page.text, contains('Holiday 2026'));
    expect(page.text, contains('notes.txt'));
    expect(page.text, contains('/trip/f/day%201/'));
    final sub = await _send('GET', url('/trip/f/day%201/'));
    expect(sub.status, 200);
    expect(sub.text, contains('map.pdf'));
    final file = await _send('GET', url('/trip/f/day%201/map.pdf'));
    expect(file.body, [1, 2, 3]);
    final escape = await _send('GET', url('/trip/f/..%2F..%2Fetc%2Fpasswd'));
    expect(escape.status, 400);
    final missing = await _send('GET', url('/trip/f/nope.txt'));
    expect(missing.status, 404);

    final zip = await _send('GET', url('/trip/zip'));
    expect(zip.status, 200);
    expect(zip.headers.contentType!.mimeType, 'application/zip');
    expect(zip.headers.contentLength, zip.body.length);
    final out = File(p.join(temp.path, 'trip.zip'));
    await out.writeAsBytes(zip.body);
    try {
      final check =
          await Process.run(Platform.isWindows ? 'python' : 'python3', [
            '-c',
            'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); '
                'print(z.testzip(), sorted(z.namelist()))',
            out.path,
          ]);
      expect(check.exitCode, 0, reason: '${check.stderr}');
      expect(check.stdout as String, startsWith('None'));
      expect(check.stdout as String, contains('Holiday 2026/day 1/map.pdf'));
    } on ProcessException {
      markTestSkipped('python3 not available');
    }
  });

  test('a file opened from its folder gets its own page', () async {
    await File(p.join(folder, 'a.txt')).writeAsString('first file');
    await File(p.join(folder, 'z.txt')).writeAsString('last file');
    await store.create(paths: [folder], route: 'pages');
    final listing = await _send('GET', url('/pages/'));
    // Files lead to their pages, folders to their listings.
    expect(listing.text, contains('/pages/f/notes.txt?view=1'));
    expect(listing.text, contains('/pages/f/notes.txt?dl=1'));
    expect(listing.text, contains('/pages/f/day%201/"'));
    final page = await _send(
      'GET',
      url('/pages/f/notes.txt?view=1'),
      headers: {'accept-language': 'en'},
    );
    expect(page.status, 200);
    expect(page.headers.contentType!.mimeType, 'text/html');
    // The start of the text, the way back and the neighbours.
    expect(page.text, contains('<pre tabindex="0">notes</pre>'));
    expect(page.text, contains('href="/pages/"'));
    expect(page.text, contains('rel="prev" href="/pages/f/a.txt?view=1"'));
    expect(page.text, contains('rel="next" href="/pages/f/z.txt?view=1"'));
    expect(page.text, contains('2 / 3'));
    expect(page.text, contains('href="/pages/f/notes.txt?dl=1" download'));
    expect(page.text, contains('From Test Mac'));
    // Without ?view=1 it is still the file itself.
    final raw = await _send('GET', url('/pages/f/notes.txt'));
    expect(raw.text, 'notes');
    expect(raw.headers.contentType!.mimeType, 'text/plain');
  });

  test('names are escaped on every page', () async {
    final evil = p.join(folder, '<img src=x onerror=alert(1)>.txt');
    if (Platform.isWindows) {
      markTestSkipped('Windows names cannot hold < and >');
      return;
    }
    await File(evil).writeAsString('x');
    await store.create(paths: [folder], route: 'esc');
    final listing = await _send('GET', url('/esc/'));
    expect(listing.text, isNot(contains('<img src=x')));
    expect(listing.text, contains('&lt;img src=x onerror=alert(1)&gt;.txt'));
    final page = await _send(
      'GET',
      url(
        '/esc/f/${Uri.encodeComponent('<img src=x onerror=alert(1)>.txt')}?view=1',
      ),
    );
    expect(page.status, 200);
    expect(page.text, isNot(contains('<img src=x')));
    expect(
      page.headers.value('content-security-policy'),
      contains("default-src 'none'"),
    );
  });

  test('the home-screen icon is served when the app has one', () async {
    await restartWith(
      (source) => ShareServer(
        source: source,
        clock: () => now,
        touchIcon: () async => [0x89, 0x50, 0x4e, 0x47],
      ),
    );
    await store.create(paths: [movie], route: 'icon');
    final icon = await _send('GET', url('/apple-touch-icon.png'));
    expect(icon.status, 200);
    expect(icon.headers.contentType!.mimeType, 'image/png');
    expect(icon.body, [0x89, 0x50, 0x4e, 0x47]);
  });

  test('passwords: login page, wrong guesses, cookie per link', () async {
    final locked = await store.create(
      paths: [movie],
      route: 'locked',
      password: 'sesame',
    );
    await store.create(paths: [folder], route: 'other', password: 'other');
    final gate = await _send('GET', url('/locked'));
    expect(gate.status, 401);
    expect(gate.text, contains('type="password"'));
    expect(gate.text, isNot(contains('电影.mp4')));
    final direct = await _send('GET', url('/locked/f/x?dl=1'));
    expect(direct.status, 401);

    final wrong = await _send(
      'POST',
      url('/locked/login'),
      form: 'password=nope&next=%2Flocked%2F',
    );
    expect(wrong.status, 401);
    expect(wrong.text, contains('role="alert"'));
    expect(wrong.headers['set-cookie'], isNull);

    final right = await _send(
      'POST',
      url('/locked/login'),
      form: 'password=sesame&next=%2Flocked%2Ff%2Fx%3Fdl%3D1',
    );
    expect(right.status, 303);
    expect(right.headers.value('location'), '/locked/f/x?dl=1');
    final cookie = right.headers['set-cookie']!.single;
    expect(cookie, contains('HttpOnly'));
    expect(cookie.toLowerCase(), contains('samesite=lax'));
    expect(cookie, contains('Path=/locked'));
    final pair = cookie.split(';').first;

    final page = await _send('GET', url('/locked'), headers: {'cookie': pair});
    expect(page.status, 200);
    expect(page.text, contains('电影.mp4'));

    // The cookie opens only the link it was given for.
    final otherLink = store.links.firstWhere((l) => l.route == 'other');
    final forged =
        '${ShareCookieSigner.cookieName(otherLink.id)}='
        '${pair.substring(pair.indexOf('=') + 1)}';
    final other = await _send(
      'GET',
      url('/other'),
      headers: {'cookie': forged},
    );
    expect(other.status, 401);

    // An open redirect is not possible through `next`.
    final sneaky = await _send(
      'POST',
      url('/locked/login'),
      form: 'password=sesame&next=%2F%2Fevil.example%2F',
    );
    expect(sneaky.headers.value('location'), '/locked/');
    expect(locked.hasPassword, isTrue);
  });

  test('guessing routes or passwords is slowed down', () async {
    await store.create(paths: [movie], route: 'real', password: 'pw');
    for (var i = 0; i < 9; i++) {
      final reply = await _send('GET', url('/guess$i'));
      expect(reply.status, 404, reason: 'attempt $i');
    }
    final favicon = await _send('GET', url('/favicon.ico'));
    expect(favicon.status, 404, reason: 'not counted');
    final tenth = await _send(
      'POST',
      url('/real/login'),
      form: 'password=wrong',
    );
    // The tenth mistake is still told it was wrong; then the wait begins.
    expect(tenth.status, 401);
    expect(tenth.text, contains('role="alert"'));
    final blocked = await _send('GET', url('/real'));
    expect(blocked.status, 429);
    expect(blocked.headers.value('retry-after'), '60');
    final stillBlocked = await _send(
      'POST',
      url('/real/login'),
      form: 'password=pw',
    );
    expect(stillBlocked.status, 429, reason: 'not even the right password');
    now = now.add(const Duration(seconds: 61));
    final later = await _send('GET', url('/real'));
    expect(later.status, 401);
  });

  test('a public host name pointing here is refused', () async {
    await store.create(paths: [movie], route: 'rebind');
    final reply = await _send(
      'GET',
      url('/rebind'),
      headers: {'host': 'attacker.example.com:${store.port}'},
    );
    expect(reply.status, 421);
    expect(reply.text, isNot(contains('电影.mp4')));
    final local = await _send(
      'GET',
      url('/rebind'),
      headers: {'host': 'my-mac.local:${store.port}'},
    );
    expect(local.status, 200);
  });

  test('guesses sent in parallel are not checked in parallel', () async {
    await store.create(paths: [movie], route: 'race', password: 'right');
    final replies = await Future.wait([
      for (var i = 0; i < 8; i++)
        _send('POST', url('/race/login'), form: 'password=wrong$i'),
    ]);
    final checked = replies.where((r) => r.status == 401).length;
    final refused = replies.where((r) => r.status == 429).length;
    // One at a time per client: the rest are told to wait, not queued.
    expect(checked, 1);
    expect(refused, 7);
    // Every check is counted before it runs: nine more and the tenth
    // overall is the last one let through.
    for (var i = 0; i < 9; i++) {
      final reply = await _send(
        'POST',
        url('/race/login'),
        form: 'password=again$i',
      );
      expect(reply.status, 401, reason: 'guess ${i + 2}');
    }
    final blocked = await _send(
      'POST',
      url('/race/login'),
      form: 'password=right',
    );
    expect(blocked.status, 429);
  });

  test('a right password after a few wrong ones lets the visitor in', () async {
    await store.create(paths: [movie], route: 'oops', password: 'right');
    for (var i = 0; i < 9; i++) {
      await _send('POST', url('/oops/login'), form: 'password=no$i');
    }
    // The tenth try is counted before it is checked; being right, it
    // clears the count, so the redirect that follows is not blocked.
    final right = await _send(
      'POST',
      url('/oops/login'),
      form: 'password=right',
    );
    expect(right.status, 303);
    final cookie = right.headers['set-cookie']!.single.split(';').first;
    final page = await _send('GET', url('/oops'), headers: {'cookie': cookie});
    expect(page.status, 200);
  });

  test('connections are capped in all and per client', () async {
    await restartWith(
      (source) => ShareServer(
        source: source,
        clock: () => now,
        maxConnections: 3,
        maxConnectionsPerClient: 2,
      ),
    );
    await store.create(paths: [movie], route: 'caps');
    Future<Socket> open() =>
        Socket.connect(InternetAddress.loopbackIPv4, store.port);
    Future<bool> refused(Socket socket) async {
      // A refused connection is closed at once, before any request.
      try {
        await socket.first.timeout(const Duration(seconds: 2));
        return true;
      } on StateError {
        return true;
      } on TimeoutException {
        return false;
      } on SocketException {
        return true;
      }
    }

    final a = await open();
    final b = await open();
    final c = await open();
    expect(await refused(c), isTrue, reason: 'third from the same client');
    a.destroy();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final d = await open();
    expect(await refused(d), isFalse, reason: 'a place was freed');
    b.destroy();
    d.destroy();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final page = await _send('GET', url('/caps'));
    expect(page.status, 200);
  });

  test('a password form that trickles in is cut off', () async {
    await restartWith(
      (source) => ShareServer(
        source: source,
        clock: () => now,
        formTimeout: const Duration(milliseconds: 300),
      ),
    );
    await store.create(paths: [movie], route: 'slow', password: 'pw');
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      store.port,
    );
    socket.write(
      'POST /slow/login HTTP/1.1\r\nHost: 127.0.0.1\r\n'
      'Content-Type: application/x-www-form-urlencoded\r\n'
      'Content-Length: 100\r\n\r\npassword=',
    );
    final reply = await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 5));
    socket.destroy();
    expect(reply, startsWith('HTTP/1.1 408'));
  });

  test('a zip of too many files is refused up front', () async {
    await restartWith(
      (source) =>
          ShareServer(source: source, clock: () => now, maxZipEntries: 2),
    );
    await store.create(paths: [folder], route: 'many');
    final zip = await _send('GET', url('/many/zip'));
    expect(zip.status, 413);
    expect(zip.headers.contentType!.mimeType, 'text/html');
  });

  test('turned-off and unknown links look the same', () async {
    final link = await store.create(paths: [movie], route: 'gone');
    await store.create(paths: [folder], route: 'keep');
    await store.setEnabled(link.id, false);
    final off = await _send('GET', url('/gone'));
    final unknown = await _send('GET', url('/never'));
    expect(off.status, 404);
    expect(unknown.status, 404);
    expect(off.text, unknown.text);
  });

  test('turning a link off cuts its downloads in progress', () async {
    final big = p.join(temp.path, 'big.bin');
    final sink = File(big).openWrite();
    final chunk = List<int>.filled(1 << 20, 7);
    for (var i = 0; i < 64; i++) {
      sink.add(chunk);
    }
    await sink.close();
    final link = await store.create(paths: [big], route: 'big');
    await store.create(paths: [folder], route: 'stay');
    final request = await _client.getUrl(url('/big/f/big.bin?dl=1'));
    final response = await request.close();
    expect(response.statusCode, 200);
    var received = 0;
    final done = Completer<Object?>();
    late StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      (data) {
        received += data.length;
        if (received > (1 << 20)) {
          // Slow reader: let the server fill its buffers, then turn off.
          subscription.pause();
          unawaited(
            store.setEnabled(link.id, false).then((_) => subscription.resume()),
          );
        }
      },
      onError: (Object error) => done.complete(error),
      onDone: () => done.complete(null),
      cancelOnError: true,
    );
    final outcome = await done.future.timeout(const Duration(seconds: 20));
    expect(received, lessThan(64 << 20));
    expect(outcome, isA<HttpException>());
  });

  test('links, counters and the password survive a restart', () async {
    final link = await store.create(
      paths: [movie, folder],
      route: 'keepme',
      password: 'pw',
      name: '两样东西',
    );
    await store.setServiceOn(true);
    final gate = await _send('GET', url('/keepme'));
    expect(gate.status, 401);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await store.shutdown();
    store.dispose();

    store = makeStore();
    await store.initialize();
    final restored = store.links.single;
    expect(restored.id, link.id);
    expect(restored.route, 'keepme');
    expect(restored.name, '两样东西');
    expect(restored.items.map((i) => i.isDir), [false, true]);
    expect(restored.visits, 1);
    expect(await restored.password!.verify('pw'), isTrue);
    expect(store.serverState.phase, ShareServerPhase.running);
    final stored = prefs.values[ShareLinkStore.linksKey] as String;
    expect(stored, isNot(contains('"pw"')));
    final right = await _send(
      'POST',
      url('/keepme/login'),
      form: 'password=pw',
    );
    expect(right.status, 303);
  });

  test('typed routes are checked', () async {
    await store.create(paths: [movie], route: 'mine');
    await expectLater(
      store.create(paths: [movie], route: 'MINE'),
      throwsA(
        isA<ShareRouteException>().having(
          (e) => e.problem,
          'problem',
          ShareRouteProblem.taken,
        ),
      ),
    );
    await expectLater(
      store.create(paths: [movie], route: 'zip'),
      throwsA(
        isA<ShareRouteException>().having(
          (e) => e.problem,
          'problem',
          ShareRouteProblem.reserved,
        ),
      ),
    );
    await expectLater(
      store.create(paths: [movie], route: 'a/b'),
      throwsA(isA<ShareRouteException>()),
    );
    await expectLater(
      store.create(paths: [p.join(temp.path, 'nothing')]),
      throwsA(isA<ShareLinkException>()),
    );
    final short = await store.create(paths: [movie], short: true);
    expect(short.route.length, 4);
  });

  test('missing files show on the link', () async {
    final link = await store.create(paths: [movie, folder]);
    await store.refreshAvailability();
    expect(store.availabilityOf(link), ShareAvailability.available);
    await File(movie).delete();
    await store.refreshAvailability();
    expect(store.availabilityOf(link), ShareAvailability.partlyMissing);
    await Directory(folder).delete(recursive: true);
    await store.refreshAvailability();
    expect(store.availabilityOf(link), ShareAvailability.missing);
    final page = await _send('GET', url('/${link.route}'));
    expect(page.status, 404);
  });

  test('debug commands drive the store and answer in JSON', () async {
    Future<Map<String, Object?>> run(
      String command, [
      Map<String, String> params = const {},
      bool ok = true,
    ]) async {
      final (worked, body) = await runShareDebugCommand(store, command, params);
      expect(worked, ok, reason: '$command $body');
      // What goes over the VM service must encode.
      return jsonDecode(jsonEncode(body)) as Map<String, Object?>;
    }

    final created = await run('create', {
      'paths': jsonEncode([movie, folder]),
      'route': 'Debug',
      'password': 'pw',
    });
    expect(created['route'], 'debug');
    expect(created['password'], isTrue);
    expect((created['items'] as List).length, 2);
    expect(created['urls'], ['http://127.0.0.1:$base/debug']);
    final id = created['id'] as String;

    final taken = await run('create', {
      'paths': jsonEncode([movie]),
      'route': 'debug',
    }, false);
    expect(taken, {'error': 'route', 'problem': 'taken'});
    final nothing = await run('create', {
      'paths': jsonEncode([p.join(temp.path, 'gone')]),
    }, false);
    expect(nothing['problem'], 'itemsMissing');

    final listed = await run('list');
    expect((listed['links'] as List).single['id'], id);
    expect((listed['server'] as Map)['phase'], 'running');

    final off = await run('setEnabled', {'id': id, 'enabled': 'false'});
    expect(off['enabled'], isFalse);
    expect(await _listening(base), isFalse);
    await run('setEnabled', {'id': id, 'enabled': 'true'});
    final service = await run('service', {'on': 'false'});
    expect(service['service'], isFalse);
    expect((service['server'] as Map)['phase'], 'stopped');
    await run('service', {'on': 'true'});
    expect(await _listening(base), isTrue);

    await run('remove', {'id': id});
    expect(await run('remove', {'id': id}, false), {
      'error': 'missing',
      'id': id,
    });
    expect((await run('nope', {}, false))['error'], 'unknown');
  });

  test('clients outside the LAN are cut off before HTTP', () async {
    await store.shutdown();
    store.dispose();
    store = ShareLinkStore(
      preferences: prefs,
      addresses: () async => ['127.0.0.1'],
      deviceName: () async => 'Test Mac',
      defaultPort: base,
      portSpan: 3,
      server: (source) =>
          ShareServer(source: source, allowClient: (_) => false),
    );
    await store.initialize();
    await store.create(paths: [movie], route: 'lan');
    await expectLater(
      _send('GET', url('/lan')),
      throwsA(anyOf(isA<HttpException>(), isA<SocketException>())),
    );
  });
}
