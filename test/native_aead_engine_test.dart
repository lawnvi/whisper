import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:whisper/socket/aead_engine.dart';
import 'package:whisper/socket/authenticated_frame.dart';

void main() {
  setUpAll(() async {
    WhisperAead.installNativeAcceleration(await SodiumInit.init());
  });

  test('native AEAD round-trips a transfer-sized payload', () async {
    final sendKey = SecretKey(List<int>.generate(32, (index) => index));
    final receiveKey = SecretKey(List<int>.generate(32, (index) => index + 32));
    final sender = await AuthenticatedFrameCodec.create(
      sendKey: sendKey,
      receiveKey: receiveKey,
    );
    final receiver = await AuthenticatedFrameCodec.create(
      sendKey: SecretKey(List<int>.generate(32, (index) => index + 32)),
      receiveKey: SecretKey(List<int>.generate(32, (index) => index)),
    );
    final buffer = AuthenticatedPayloadBuffer.allocate(1024 * 1024);
    for (var index = 0; index < buffer.payload.length; index += 1) {
      buffer.payload[index] = index & 0xff;
    }
    final payload = Uint8List.fromList(buffer.payload);

    final frame = await sender.encodeBuffer(buffer);

    expect(identical(frame, buffer.bytes), isTrue);
    expect(await receiver.decode(frame), orderedEquals(payload));
    sender.close();
    receiver.close();
  });

  test('native AEAD rejects a modified authentication tag', () async {
    final sender = await AuthenticatedFrameCodec.create(
      sendKey: SecretKey(List<int>.filled(32, 1)),
      receiveKey: SecretKey(List<int>.filled(32, 2)),
    );
    final receiver = await AuthenticatedFrameCodec.create(
      sendKey: SecretKey(List<int>.filled(32, 2)),
      receiveKey: SecretKey(List<int>.filled(32, 1)),
    );
    final frame = await sender.encode(Uint8List.fromList(<int>[1, 2, 3]));
    frame[frame.length - 1] ^= 1;

    await expectLater(
      receiver.decode(frame),
      throwsA(isA<AuthenticatedFrameException>()),
    );
    sender.close();
    receiver.close();
  });
}
