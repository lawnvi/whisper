import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/share_links/share_link_store.dart';
import 'package:whisper/web_transfer/web_transfer_coordinator.dart';
import 'package:whisper/web_transfer/web_transfer_visitor.dart';

// Web transfer over real sockets: a browser's page is played by a WebSocket
// and HttpClient. docs/internals/web-transfer.md「测试」.

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

const _self = DeviceData(
  id: 0,
  uid: 'self-uid',
  name: 'Host',
  host: '127.0.0.1',
  port: 10002,
  platform: 'macos',
  isServer: true,
  online: true,
  clipboard: false,
  auth: true,
  lastTime: 0,
);

class _Harness {
  late final LocalDatabase db;
  late final ShareLinkStore links;
  late final WebTransferCoordinator web;
  late final Directory received;
  final messages = <MessageData>[];
  final transfers = <TransferSnapshot>[];
  final client = HttpClient();

  int get port => links.port;
  String get origin => 'http://127.0.0.1:$port';

  Future<void> start({
    Duration answer = const Duration(seconds: 30),
    Duration away = const Duration(seconds: 30),
    int maxSessions = 4,
  }) async {
    received = await Directory.systemTemp.createTemp('web-transfer-');
    db = LocalDatabase.forTesting(NativeDatabase.memory());
    links = ShareLinkStore(
      preferences: _MemoryPreferences(),
      addresses: () async => ['127.0.0.1'],
      deviceName: () async => 'Host',
      defaultPort: 0,
      portSpan: 0,
    );
    web = WebTransferCoordinator(
      database: db,
      links: links,
      self: () async => _self,
      selfName: () async => 'Host <Mac>',
      receiveDirectory: () async => received,
      // CRLF, as a Windows checkout has it (git's autocrlf). Regression: the
      // page was blank there because its CSP hashes were taken over CRLF, but
      // browsers hash inline blocks with LF line ends and refused them.
      loadPage: () async => (await File(
        'assets/web_transfer/index.html',
      ).readAsString()).replaceAll('\n', '\r\n'),
      onMessage: messages.add,
      onTransfer: transfers.add,
      answerTimeout: answer,
      awayTimeout: away,
      maxSessions: maxSessions,
    );
    await web.open();
  }

  Future<void> stop() async {
    await web.shutdown();
    await links.shutdown();
    client.close(force: true);
    await db.close();
    await received.delete(recursive: true);
  }

  Future<_Page> page(String key, {String? origin}) async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:$port/w/ws',
      headers: {'origin': origin ?? this.origin},
    );
    final page = _Page(socket, key);
    page.send({
      't': 'hello',
      'v': 1,
      'key': key,
      'os': 'ios',
      'kind': 'phone',
      'browser': 'safari',
    });
    return page;
  }

  /// A visitor asked and was let in; its cookie is set.
  Future<_Page> join(String key) async {
    final page = await this.page(key);
    final wait = await page.next('wait');
    expect(wait['code'], matches(RegExp(r'^\d{4}$')));
    expect(web.requests.single.code, wait['code']);
    await web.answer(webVisitorUid(key), true);
    final welcome = await page.next('welcome');
    page.cookie = await session(welcome['session'] as String);
    return page;
  }

  Future<String> session(String token) async {
    final reply = await send(
      'POST',
      '/w/session',
      body: utf8.encode(jsonEncode({'token': token})),
    );
    expect(reply.status, HttpStatus.noContent);
    final cookie = reply.headers['set-cookie']!.single;
    expect(cookie, contains('HttpOnly'));
    expect(cookie, contains('SameSite=Strict'));
    return cookie.split(';').first;
  }

  Future<_Reply> send(
    String method,
    String path, {
    String? cookie,
    Map<String, String> headers = const {},
    List<int>? body,
    bool sameOrigin = true,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    if (sameOrigin) {
      request.headers.set('origin', origin);
    }
    if (cookie != null) {
      request.headers.set('cookie', cookie);
    }
    headers.forEach(request.headers.set);
    if (body != null) {
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close();
    final bytes = await response.fold<List<int>>([], (a, b) => a..addAll(b));
    return _Reply(response.statusCode, response.headers, bytes);
  }

  Future<_Reply> put(
    String id,
    int start,
    List<int> bytes,
    int total, {
    String? cookie,
  }) => send(
    'PUT',
    '/w/up/$id',
    cookie: cookie,
    headers: {
      'content-range': total == 0
          ? 'bytes 0-0/0'
          : 'bytes $start-${start + bytes.length - 1}/$total',
    },
    body: bytes,
  );
}

class _Reply {
  _Reply(this.status, this.headers, this.body);

  final int status;
  final HttpHeaders headers;
  final List<int> body;

  Map<String, Object?> get json =>
      jsonDecode(utf8.decode(body)) as Map<String, Object?>;
}

class _Page {
  _Page(this.socket, this.key) {
    socket.listen(
      (data) => _frames.add(jsonDecode(data as String) as Map<String, Object?>),
      onDone: () => _frames.add({'t': '<closed>'}),
    );
  }

  final WebSocket socket;
  final String key;
  String? cookie;
  final _frames = StreamController<Map<String, Object?>>();
  late final _queue = StreamIterator(_frames.stream);

  void send(Map<String, Object?> frame) => socket.add(jsonEncode(frame));

  /// The next frame of [type], skipping others.
  Future<Map<String, Object?>> next(String type) async {
    while (await _queue.moveNext().timeout(const Duration(seconds: 5))) {
      if (_queue.current['t'] == type) {
        return _queue.current;
      }
    }
    throw StateError('closed before $type');
  }
}

Future<void> _eventually<T>(Future<T> Function() read, T expected) async {
  for (var i = 0; i < 40 && await read() != expected; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(await read(), expected);
}

String _key(int n) => 'k${n.toString().padLeft(21, '0')}';

String _uuid(int n) =>
    '00000000-0000-4000-8000-${n.toRadixString(16).padLeft(12, '0')}';

void main() {
  late _Harness h;

  setUp(() => h = _Harness());
  tearDown(() => h.stop());

  test('the main path: ask, allow, texts both ways, a resumed upload and a '
      'ranged download', () async {
    await h.start();
    final pageHtml = await h.send('GET', '/', sameOrigin: false);
    expect(pageHtml.status, HttpStatus.ok);
    final html = utf8.decode(pageHtml.body);
    // The name is data in the page, never markup.
    expect(html, contains(r'"name":"Host <Mac>"'));
    expect(
      pageHtml.headers.value('content-security-policy'),
      allOf(contains("default-src 'none'"), contains("script-src 'sha256-")),
    );
    final script = RegExp(
      r'<script>([\s\S]*?)</script>',
    ).firstMatch(html.replaceAll('\r\n', '\n'))!.group(1)!;
    expect(
      pageHtml.headers.value('content-security-policy'),
      contains(
        "'sha256-${base64.encode(sha256.convert(utf8.encode(script)).bytes)}'",
      ),
    );

    final page = await h.join(_key(1));
    final uid = webVisitorUid(_key(1));
    expect(h.web.onlineUids, {uid});
    expect((await h.db.fetchDevice(uid))!.platform, 'ios');

    page.send({'t': 'text', 'id': _uuid(1), 'body': 'hi from the web'});
    expect((await page.next('ack'))['id'], _uuid(1));
    // Sent again after a reconnect: kept once.
    page.send({'t': 'text', 'id': _uuid(1), 'body': 'hi from the web'});
    await page.next('ack');
    expect(h.messages.where((m) => m.uuid == _uuid(1)).single.sender, uid);

    expect(await h.web.sendText(uid, 'hi from here'), isTrue);
    final text = await page.next('text');
    expect(text['from'], 'host');
    expect(text['body'], 'hi from here');

    // An upload of 3 MiB whose first PUT breaks off part way.
    final bytes = List<int>.generate(3 << 20, (i) => (i * 31) & 0xff);
    page.send({
      't': 'offer',
      'id': _uuid(2),
      'name': '../evil/report.pdf',
      'size': bytes.length,
      'type': 'application/pdf',
    });
    expect((await page.next('state'))['state'], 'ready');
    final raw = await Socket.connect('127.0.0.1', h.port);
    raw.write(
      'PUT /w/up/${_uuid(2)} HTTP/1.1\r\n'
      'host: 127.0.0.1:${h.port}\r\norigin: ${h.origin}\r\n'
      'cookie: ${page.cookie}\r\n'
      'content-range: bytes 0-${bytes.length - 1}/${bytes.length}\r\n'
      'content-length: ${bytes.length}\r\n\r\n',
    );
    raw.add(bytes.sublist(0, 1 << 20));
    await raw.flush();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    raw.destroy();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final where = await h.send('GET', '/w/up/${_uuid(2)}', cookie: page.cookie);
    final committed = where.json['committed'] as int;
    expect(committed, greaterThan(0));
    expect(committed, lessThanOrEqualTo(1 << 20));
    final rest = await h.put(
      _uuid(2),
      committed,
      bytes.sublist(committed),
      bytes.length,
      cookie: page.cookie,
    );
    expect(rest.status, HttpStatus.ok);
    expect((await page.next('state'))['state'], 'done');
    final saved = File(p.join(h.received.path, 'report.pdf'));
    expect(await saved.readAsBytes(), bytes);
    expect(
      (await h.db.fetchFileTransfer(_uuid(2)))!.state,
      FileTransferState.completed,
    );
    expect(h.received.listSync().map((e) => p.basename(e.path)), [
      'report.pdf',
    ]);

    // This device sends a file; the page reads it in two ranges.
    final out = File(p.join(h.received.path, 'out.bin'))
      ..writeAsBytesSync(List<int>.generate(5000, (i) => i & 0xff));
    expect(await h.web.sendFile(uid, out.path), isTrue);
    final offered = await page.next('file');
    final first = await h.send(
      'GET',
      '/w/f/${offered['id']}',
      cookie: page.cookie,
      headers: {'range': 'bytes=0-999'},
    );
    expect(first.status, HttpStatus.partialContent);
    expect(first.body, out.readAsBytesSync().sublist(0, 1000));
    expect(first.headers.value('content-security-policy'), contains('sandbox'));
    final second = await h.send(
      'GET',
      '/w/f/${offered['id']}',
      cookie: page.cookie,
      headers: {'range': 'bytes=1000-'},
    );
    expect(second.body, out.readAsBytesSync().sublist(1000));
    // Written down once the last byte has gone, which the page may see first.
    await _eventually(
      () async =>
          (await h.db.fetchFileTransfer(offered['id'] as String))?.state,
      FileTransferState.completed,
    );
  });

  test('what a visitor on the network can reach', () async {
    await h.start(maxSessions: 2);
    final page = await h.join(_key(1));
    final cookie = page.cookie!;
    final out = File(p.join(h.received.path, 'secret.txt'))
      ..writeAsStringSync('secret');
    final other = webVisitorUid(_key(9));
    await h.db.upsertDevice(_self.copyWith(uid: other, platform: 'ios'));
    page.send({'t': 'offer', 'id': _uuid(3), 'name': 'a', 'size': 4});
    await page.next('state');

    final cases = <String, Future<_Reply> Function()>{
      'upload without a session': () => h.put(_uuid(3), 0, [1, 2, 3, 4], 4),
      'upload from another page': () => h.send(
        'PUT',
        '/w/up/${_uuid(3)}',
        cookie: cookie,
        sameOrigin: false,
        headers: {'content-range': 'bytes 0-3/4'},
        body: [1, 2, 3, 4],
      ),
      'upload at the wrong place': () =>
          h.put(_uuid(3), 2, [3, 4], 4, cookie: cookie),
      'upload never offered': () => h.put(_uuid(4), 0, [1], 1, cookie: cookie),
      'session from another page': () => h.send(
        'POST',
        '/w/session',
        sameOrigin: false,
        body: utf8.encode(jsonEncode({'token': 'x'})),
      ),
      'a made-up session': () => h.send(
        'POST',
        '/w/session',
        body: utf8.encode(jsonEncode({'token': 'x' * 43})),
      ),
      'download without a session': () => h.send('GET', '/w/f/${_uuid(5)}'),
      'download of something never sent': () =>
          h.send('GET', '/w/f/${_uuid(3)}', cookie: cookie),
    };
    final expected = {
      'upload without a session': HttpStatus.forbidden,
      'upload from another page': HttpStatus.forbidden,
      'upload at the wrong place': HttpStatus.conflict,
      'upload never offered': HttpStatus.notFound,
      'session from another page': HttpStatus.forbidden,
      'a made-up session': HttpStatus.forbidden,
      'download without a session': HttpStatus.forbidden,
      'download of something never sent': HttpStatus.notFound,
    };
    for (final MapEntry(:key, :value) in cases.entries) {
      expect((await value()).status, expected[key], reason: key);
    }

    // A file sent to someone else is not this visitor's to fetch.
    await h.db.insertMessageReturning(
      MessageData(
        id: 0,
        sender: _self.uid,
        receiver: other,
        name: 'secret.txt',
        clipboard: false,
        size: 6,
        type: MessageEnum.File,
        timestamp: 0,
        uuid: _uuid(6),
        acked: true,
        path: out.path,
        md5: '',
      ),
    );
    expect(
      (await h.send('GET', '/w/f/${_uuid(6)}', cookie: cookie)).status,
      HttpStatus.notFound,
    );

    // A WebSocket from another page is refused before it opens.
    await expectLater(
      h.page(_key(2), origin: 'http://evil.example'),
      throwsA(isA<WebSocketException>()),
    );

    // Over the limit: two visits in all.
    final second = await h.page(_key(3));
    await second.next('wait');
    final third = await h.page(_key(4));
    await third.next('busy');

    // Closed panel: a new visitor hears so and nothing is asked.
    await h.web.close();
    final late = await h.page(_key(5));
    final closed = await late.next('closed');
    expect((closed['host'] as Map)['name'], 'Host <Mac>');
    expect(h.web.requests.map((r) => r.uid), [webVisitorUid(_key(3))]);

    // Ended: the cookie opens nothing any more.
    await h.web.end(webVisitorUid(_key(1)));
    expect((await page.next('ended'))['by'], 'host');
    expect(
      (await h.send('GET', '/w/up/${_uuid(3)}', cookie: cookie)).status,
      HttpStatus.notFound,
    );
    expect(
      (await h.put(_uuid(3), 0, [1, 2, 3, 4], 4, cookie: cookie)).status,
      HttpStatus.forbidden,
    );
    await _eventually(
      () async => (await h.db.fetchFileTransfer(_uuid(3)))?.state,
      FileTransferState.failed,
    );
  });

  test('a request expires, a visit survives a short break and ends after a '
      'long one', () async {
    await h.start(
      answer: const Duration(milliseconds: 300),
      away: const Duration(milliseconds: 600),
    );
    final asking = await h.page(_key(1));
    await asking.next('wait');
    await asking.next('expired');
    expect(h.web.requests, isEmpty);

    final page = await h.join(_key(2));
    final uid = webVisitorUid(_key(2));
    await page.socket.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(h.web.onlineUids, isEmpty);
    expect(h.web.canSend(uid), isTrue);
    // Sent while away: delivered with the history on return.
    await h.web.sendText(uid, 'while you were away');

    final back = await h.page(_key(2));
    final welcome = await back.next('welcome');
    expect(
      (welcome['history'] as List).map((e) => (e as Map)['body']),
      contains('while you were away'),
    );
    expect(h.web.onlineUids, {uid});

    await back.socket.close();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(h.web.canSend(uid), isFalse);
    // Back again after the end: asked anew.
    final again = await h.page(_key(2));
    await again.next('wait');
  });
}
