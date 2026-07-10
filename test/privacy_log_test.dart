import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/privacy_log.dart';

void main() {
  test('shortId returns a deterministic domain-separated 12 hex digest', () {
    final lines = <String>[];
    final log = PrivacyLog(sink: lines.add);
    const raw = '2f7f51bb-1df3-4dd4-a2e4-728faea27d38';

    final first = log.shortId(PrivacyIdKind.peer, raw);
    final second = log.shortId(PrivacyIdKind.peer, raw);
    final plainDigest = sha256.convert(utf8.encode(raw)).toString();

    expect(first.value, second.value);
    expect(first.value, matches(RegExp(r'^[0-9a-f]{12}$')));
    expect(first.value, isNot(raw));
    expect(first.value, isNot(plainDigest.substring(0, 12)));
    expect(lines, isEmpty);
  });

  test('shortId accepts only canonical high-entropy identifiers', () {
    final log = PrivacyLog(sink: (_) {});
    const uuid = '2f7f51bb-1df3-4dd4-a2e4-728faea27d38';

    final peer = log.shortId(PrivacyIdKind.peer, uuid);
    final transfer = log.shortId(PrivacyIdKind.transfer, uuid);

    expect(peer.value, matches(RegExp(r'^[0-9a-f]{12}$')));
    expect(transfer.value, isNot(peer.value));
    for (final unsafe in <String>[
      '',
      'abc',
      '482913',
      'token_never_log_this',
      'recognizable_secret_message_body',
      'MCowBQYDK2VwAyEApublic_key_material_never_log',
      '2F7F51BB-1DF3-4DD4-A2E4-728FAEA27D38',
      '2f7f51bb1df34dd4a2e4728faea27d38',
    ]) {
      expect(
        () => log.shortId(PrivacyIdKind.peer, unsafe),
        throwsArgumentError,
      );
    }
  });

  test('shortId rejection never includes the rejected identifier', () {
    final log = PrivacyLog(sink: (_) {});
    const secret = 'pairing-code-482913-token-never-log-this';

    Object? thrown;
    try {
      log.shortId(PrivacyIdKind.peer, secret);
    } catch (error) {
      thrown = error;
    }

    expect(thrown, isA<ArgumentError>());
    expect(thrown.toString(), isNot(contains(secret)));
    expect(thrown.toString(), isNot(contains('482913')));
    expect(thrown.toString(), isNot(contains('token-never-log-this')));
  });

  test('redactUri maps only exact allowlisted paths to route categories', () {
    final log = PrivacyLog(sink: (_) {});

    expect(
      log.redactUri(
        Uri.parse(
          'ws://alice:secret@[fe80::1234]:9200/audio?token=top-secret#part',
        ),
      ),
      PrivacyRoute.audio,
    );
    expect(
      log.redactUri(Uri.parse('ws://192.0.2.44:9200/chat')),
      PrivacyRoute.chat,
    );
    expect(
      log.redactUri(Uri.parse('ws://peer.private.example:9200/input')),
      PrivacyRoute.input,
    );

    for (final uri in <Uri>[
      Uri.parse('ws://peer.private.example:9200/audio/private'),
      Uri.parse('ws://peer.private.example:9200/audio/'),
      Uri.parse('ws://peer.private.example:9200/AUDIO'),
      Uri.parse('content://private.provider/root/secret.txt'),
    ]) {
      expect(log.redactUri(uri), PrivacyRoute.other);
    }
  });

  test('errorType keeps only a sanitized runtime type without error text', () {
    final log = PrivacyLog(sink: (_) {});
    final error = _RemoteFailure(
      'remote rejected token=never-log-this /Users/alice/private.txt',
    );

    final type = log.errorType(error);
    final trap = _RuntimeTypeTrap();
    final genericType = log.errorType(trap);

    expect(type.value, PrivacyErrorKind.unknown.name);
    expect(type.value, isNot(contains('never-log-this')));
    expect(error.toStringCalled, isFalse);
    expect(genericType.value, PrivacyErrorKind.unknown.name);
    expect(trap.runtimeTypeRead, isFalse);
  });

  test('event emits stable sorted JSON for branded safe values', () {
    final lines = <String>[];
    final log = PrivacyLog(sink: lines.add);
    const transferId = '2f7f51bb-1df3-4dd4-a2e4-728faea27d38';
    const peerId = 'peer-7e581a29-38cd-4451-871a-d5cb31c78f03';
    final remoteError = _RemoteFailure('remote detail token=never-log-this');
    final shortTransferId = log.shortId(PrivacyIdKind.transfer, transferId);
    final shortPeerId = log.shortId(
      PrivacyIdKind.peer,
      '7e581a29-38cd-4451-871a-d5cb31c78f03',
    );

    log.event(PrivacyEvent.transferProgress, <PrivacyField, Object>{
      PrivacyField.transferId: shortTransferId,
      PrivacyField.state: _TransferState.receiving,
      PrivacyField.route: log.redactUri(
        Uri.parse(
          'ws://user:password@peer.private.example:9200/audio'
          '?token=never-log-this#fragment',
        ),
      ),
      PrivacyField.retrying: false,
      PrivacyField.peerId: shortPeerId,
      PrivacyField.errorType: log.errorType(remoteError),
      PrivacyField.bytes: 4096,
    });

    expect(lines, hasLength(1));
    expect(
      lines.single,
      '{"bytes":4096,"errorType":"unknown",'
      '"event":"transfer_progress","peerId":"${shortPeerId.value}",'
      '"retrying":false,"route":"audio","state":"receiving",'
      '"transferId":"${shortTransferId.value}"}',
    );
    expect(lines.single, isNot(contains(transferId)));
    expect(lines.single, isNot(contains(peerId)));
    expect(lines.single, isNot(contains('never-log-this')));
    expect(lines.single, isNot(contains('peer.private.example')));
    expect(remoteError.toStringCalled, isFalse);
  });

  test('event rejects raw or composite values without invoking the sink', () {
    final lines = <String>[];
    final log = PrivacyLog(sink: lines.add);
    final rawRemoteError = _RemoteFailure('remote error should stay private');
    final forbidden = <Object>[
      'message: recognizable-secret-content',
      'notification: private title and body',
      'clipboard: private copied text',
      '2f7f51bb-1df3-4dd4-a2e4-728faea27d38',
      'MCowBQYDK2VwAyEApublic-key-material-never-log',
      '482913',
      '192.0.2.44',
      'fe80::1234%en0',
      'peer.private.example',
      '/Users/alice/Documents/private.txt',
      r'C:\Users\alice\Documents\private.txt',
      'content://private.provider/root/secret.txt',
      Uri.parse('content://private.provider/root/secret.txt'),
      Uri.parse(
        'ws://user:password@peer.private.example:9200/input'
        '?token=never-log-this#fragment',
      ),
      rawRemoteError,
      StackTrace.current,
      <Object>[true],
      <String, Object>{'nested': true},
      Object(),
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ];

    for (final value in forbidden) {
      expect(
        () => log.event(
          PrivacyEvent.testEvent,
          <PrivacyField, Object>{PrivacyField.value: value},
        ),
        throwsArgumentError,
        reason: 'accepted ${value.runtimeType}',
      );
      expect(lines, isEmpty);
    }
    expect(rawRemoteError.toStringCalled, isFalse);
  });

  test('event names and field keys are closed enums', () {
    final log = PrivacyLog(sink: (_) {});

    expect(
      () => log.event(
        'secret_482913' as dynamic,
        <PrivacyField, Object>{PrivacyField.allowed: true},
      ),
      throwsA(anything),
    );
    expect(
      () => log.event(
        PrivacyEvent.testEvent,
        <String, Object>{'token_never_log_this': true} as dynamic,
      ),
      throwsA(anything),
    );
  });
}

enum _TransferState { receiving }

final class _RemoteFailure {
  _RemoteFailure(this.message);

  final String message;
  bool toStringCalled = false;

  @override
  String toString() {
    toStringCalled = true;
    return message;
  }
}

final class _RuntimeTypeTrap {
  bool runtimeTypeRead = false;

  @override
  Type get runtimeType {
    runtimeTypeRead = true;
    throw StateError('runtimeType must not be read');
  }
}
