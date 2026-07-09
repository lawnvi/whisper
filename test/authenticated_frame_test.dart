import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/authenticated_frame.dart';

SecretKey _key(int start) => SecretKey(
      List<int>.generate(32, (index) => (start + index) & 0xff),
    );

void main() {
  test('directional codecs exchange plaintext in strict sequence', () async {
    final clientToServer = _key(0);
    final serverToClient = _key(32);
    final client = AuthenticatedFrameCodec(
      sendKey: clientToServer,
      receiveKey: serverToClient,
    );
    final server = AuthenticatedFrameCodec(
      sendKey: serverToClient,
      receiveKey: clientToServer,
    );

    final first = await client.encode(Uint8List.fromList(<int>[1, 2, 3]));
    final second = await client.encode(Uint8List.fromList(<int>[4, 5]));

    expect(await server.decode(first), orderedEquals(<int>[1, 2, 3]));
    expect(await server.decode(second), orderedEquals(<int>[4, 5]));
    expect(client.lastSentSequence, 2);
    expect(server.lastReceivedSequence, 2);
  });

  test('rejects payload and MAC tampering without consuming sequence',
      () async {
    final sendKey = _key(0);
    final receiveKey = _key(32);
    final sender = AuthenticatedFrameCodec(
      sendKey: sendKey,
      receiveKey: receiveKey,
    );
    final receiver = AuthenticatedFrameCodec(
      sendKey: receiveKey,
      receiveKey: sendKey,
    );
    final frame = await sender.encode(Uint8List.fromList(<int>[7, 8, 9]));
    final tamperedPayload = Uint8List.fromList(frame)..[18] ^= 0xff;

    await expectLater(
      receiver.decode(tamperedPayload),
      throwsA(isA<AuthenticatedFrameException>()),
    );
    expect(receiver.lastReceivedSequence, 0);
    expect(await receiver.decode(frame), orderedEquals(<int>[7, 8, 9]));

    final second = await sender.encode(Uint8List.fromList(<int>[10]));
    final tamperedMac = Uint8List.fromList(second)..[second.length - 1] ^= 1;
    await expectLater(
      receiver.decode(tamperedMac),
      throwsA(isA<AuthenticatedFrameException>()),
    );
    expect(receiver.lastReceivedSequence, 1);
  });

  test('rejects replay, gaps, and the reverse direction key', () async {
    final clientToServer = _key(0);
    final serverToClient = _key(32);
    final client = AuthenticatedFrameCodec(
      sendKey: clientToServer,
      receiveKey: serverToClient,
    );
    final server = AuthenticatedFrameCodec(
      sendKey: serverToClient,
      receiveKey: clientToServer,
    );
    final wrongDirection = AuthenticatedFrameCodec(
      sendKey: clientToServer,
      receiveKey: serverToClient,
    );

    final first = await client.encode(Uint8List.fromList(<int>[1]));
    final second = await client.encode(Uint8List.fromList(<int>[2]));

    await expectLater(
      wrongDirection.decode(first),
      throwsA(isA<AuthenticatedFrameException>()),
    );
    await expectLater(
      server.decode(second),
      throwsA(isA<AuthenticatedFrameException>()),
    );
    expect(await server.decode(first), orderedEquals(<int>[1]));
    await expectLater(
      server.decode(first),
      throwsA(isA<AuthenticatedFrameException>()),
    );
  });

  test('rejects truncated and oversized declared payload frames', () async {
    final codec = AuthenticatedFrameCodec(
      sendKey: _key(0),
      receiveKey: _key(0),
    );

    await expectLater(
      codec.decode(Uint8List(10)),
      throwsA(isA<AuthenticatedFrameException>()),
    );
    final valid = await codec.encode(Uint8List.fromList(<int>[1, 2]));
    final malformed = Uint8List.fromList(valid);
    ByteData.sublistView(malformed).setUint32(12, 3);
    await expectLater(
      AuthenticatedFrameCodec(
        sendKey: _key(0),
        receiveKey: _key(0),
      ).decode(malformed),
      throwsA(isA<AuthenticatedFrameException>()),
    );
  });

  test('concurrent encoding assigns a unique increasing sequence', () async {
    final codec = AuthenticatedFrameCodec(
      sendKey: _key(0),
      receiveKey: _key(32),
    );

    final frames = await Future.wait(
      List<Future<Uint8List>>.generate(
        20,
        (index) => codec.encode(Uint8List.fromList(<int>[index])),
      ),
    );
    final sequences = frames
        .map((frame) => ByteData.sublistView(frame, 4, 12).getUint64(0))
        .toList(growable: false);

    expect(
        sequences, orderedEquals(List<int>.generate(20, (index) => index + 1)));
    expect(codec.lastSentSequence, 20);
  });

  test('concurrent decoding accepts a frame only once', () async {
    final sender = AuthenticatedFrameCodec(
      sendKey: _key(0),
      receiveKey: _key(32),
    );
    final receiver = AuthenticatedFrameCodec(
      sendKey: _key(32),
      receiveKey: _key(0),
    );
    final frame = await sender.encode(Uint8List.fromList(<int>[1]));

    final accepted = await Future.wait(
      List<Future<bool>>.generate(
        2,
        (_) => receiver.decode(frame).then(
              (_) => true,
              onError: (_) => false,
            ),
      ),
    );

    expect(accepted.where((value) => value), hasLength(1));
    expect(receiver.lastReceivedSequence, 1);
  });
}
