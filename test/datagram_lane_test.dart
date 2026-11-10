import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/socket/datagram_endpoint.dart';
import 'package:whisper/socket/datagram_seal.dart';

final _key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
final _binding = Uint8List.fromList(List<int>.generate(32, (i) => 200 - i));

DatagramKeys _keys({String session = 'session-a', Uint8List? key}) =>
    DatagramKeys.derive(
      mediaKey: key ?? _key,
      channelBinding: _binding,
      namespace: 'remote-input',
      sessionId: session,
    );

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

void main() {
  group('sealed datagrams', () {
    test('open once, in any order within the window, and nothing else', () {
      final keys = _keys();
      final sealer = keys.sealer(DatagramDirection.fromDialer);
      final opener = _keys().opener(DatagramDirection.fromDialer);
      final sealed = [
        for (var i = 0; i < 4; i++) sealer.seal(_bytes([i])),
      ];

      // Late and out of order is fine; each only once.
      expect(opener.open(sealed[2]), _bytes([2]));
      expect(opener.open(sealed[0]), _bytes([0]));
      expect(opener.open(sealed[0]), isNull);
      expect(opener.open(sealed[3]), _bytes([3]));
      expect(opener.open(sealed[1]), _bytes([1]));
      expect(opener.open(sealed[2]), isNull);
    });

    test('refuse what is tampered, misdirected or of another session', () {
      final sealer = _keys().sealer(DatagramDirection.fromDialer);
      final sealed = sealer.seal(_bytes([1, 2, 3]));
      final cases = <String, (Uint8List, DatagramOpener)>{
        'flipped payload bit': (
          Uint8List.fromList(sealed)..[sealed.length - 1] ^= 1,
          _keys().opener(DatagramDirection.fromDialer),
        ),
        'flipped sequence bit': (
          Uint8List.fromList(sealed)..[DatagramFormat.sequenceOffset + 7] ^= 1,
          _keys().opener(DatagramDirection.fromDialer),
        ),
        // Each direction has its own key: what one end sends cannot be
        // played back to it as if from the other.
        'other direction': (sealed, _keys().opener(DatagramDirection.toDialer)),
        'other session': (
          sealed,
          _keys(session: 'session-b').opener(DatagramDirection.fromDialer),
        ),
        'other key': (
          sealed,
          _keys(
            key: Uint8List.fromList(List<int>.filled(32, 9)),
          ).opener(DatagramDirection.fromDialer),
        ),
        'truncated': (
          Uint8List.sublistView(sealed, 0, DatagramFormat.overheadBytes - 1),
          _keys().opener(DatagramDirection.fromDialer),
        ),
      };
      for (final MapEntry(key: name, value: (datagram, opener))
          in cases.entries) {
        expect(opener.open(datagram), isNull, reason: name);
      }
    });

    test('refuse a sequence a whole window behind the newest', () {
      final sealer = _keys().sealer(DatagramDirection.fromDialer);
      final opener = _keys().opener(DatagramDirection.fromDialer);
      final first = sealer.seal(_bytes([0]));
      Uint8List? last;
      for (var i = 1; i <= DatagramOpener.window; i++) {
        last = sealer.seal(_bytes([1]));
      }
      expect(opener.open(last!), isNotNull);
      expect(opener.open(first), isNull);
    });

    test('a forged datagram does not move the window', () {
      final sealer = _keys().sealer(DatagramDirection.fromDialer);
      final opener = _keys().opener(DatagramDirection.fromDialer);
      final genuine = sealer.seal(_bytes([7]));
      // Claims a sequence far ahead, but the tag is wrong.
      final forged = Uint8List.fromList(genuine);
      ByteData.sublistView(
        forged,
      ).setUint64(DatagramFormat.sequenceOffset, 1 << 40);
      expect(opener.open(forged), isNull);
      expect(opener.open(genuine), _bytes([7]));
    });
  });

  test('a lane over real sockets: the answering end learns where to answer, '
      'both stay healthy, data goes one way', () async {
    final dialerEnd = await DatagramEndpoint.bind();
    final answerEnd = await DatagramEndpoint.bind();
    final heard = <List<int>>[];
    final answering = DatagramLane(
      endpoint: answerEnd,
      keys: _keys(),
      dialer: false,
      onData: (payload) => heard.add(payload.toList()),
      keepalive: const Duration(milliseconds: 20),
    );
    final dialing = DatagramLane(
      endpoint: dialerEnd,
      keys: _keys(),
      dialer: true,
      peer: InternetAddress.loopbackIPv4,
      peerPort: answerEnd.port,
      onData: (_) {},
      keepalive: const Duration(milliseconds: 20),
    );
    addTearDown(() async {
      dialing.close();
      answering.close();
      await dialerEnd.close();
      await answerEnd.close();
    });

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!(dialing.healthy && answering.healthy)) {
      if (DateTime.now().isAfter(deadline)) fail('lane never came up');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(dialing.send(_bytes([1, 2])), isTrue);
    while (heard.isEmpty) {
      if (DateTime.now().isAfter(deadline)) fail('data never arrived');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(heard.single, [1, 2]);

    // Datagrams of no lane here, or not genuine, are dropped unread.
    final stranger = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(stranger.close);
    stranger.send(
      _keys(
        session: 'other',
      ).sealer(DatagramDirection.fromDialer).seal(_bytes([1, 0])),
      InternetAddress.loopbackIPv4,
      answerEnd.port,
    );
    stranger.send(
      _bytes([1, 2, 3]),
      InternetAddress.loopbackIPv4,
      answerEnd.port,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(heard, hasLength(1));
  });

  // A laptop that only received sound by UDP let its Wi-Fi card doze, and
  // packets waited at the access point for up to 280 ms: late sound that TCP
  // never had, as its ACKs kept the card awake. The receiving end now
  // answers while data comes in, whatever its keepalive.
  test('while data comes in, the receiving end answers often', () async {
    final dialerEnd = await DatagramEndpoint.bind();
    final answerEnd = await DatagramEndpoint.bind();
    final answering = DatagramLane(
      endpoint: answerEnd,
      keys: _keys(),
      dialer: false,
      onData: (_) {},
      keepalive: const Duration(hours: 1),
    );
    final dialing = DatagramLane(
      endpoint: dialerEnd,
      keys: _keys(),
      dialer: true,
      peer: InternetAddress.loopbackIPv4,
      peerPort: answerEnd.port,
      onData: (_) {},
      keepalive: const Duration(hours: 1),
      healthyWithin: const Duration(milliseconds: 150),
    );
    addTearDown(() async {
      dialing.close();
      answering.close();
      await dialerEnd.close();
      await answerEnd.close();
    });

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!dialing.healthy) {
      if (DateTime.now().isAfter(deadline)) fail('lane never came up');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // Long past the first answer, with no keepalive due on either end.
    for (var i = 0; i < 25; i++) {
      dialing.send(_bytes([i]));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(answering.received, 25);
    expect(dialing.healthy, isTrue);
  });
}
