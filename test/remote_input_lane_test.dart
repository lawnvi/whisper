import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_datagrams.dart';
import 'package:whisper/remote_input/remote_input_lane.dart';
import 'package:whisper/remote_input/remote_input_manager.dart';
import 'package:whisper/remote_input/remote_input_packet_transport.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/socket/datagram_endpoint.dart';
import 'package:whisper/socket/packet_byte_transport.dart';
import 'package:whisper/socket/session_upgrade_token_registry.dart';
import 'package:whisper/socket/svrmanager.dart';

class _Socket implements RemoteInputObservablePacketTransport {
  final List<RemoteInputPacketFrame> sent = [];
  @override
  void send(RemoteInputPacketFrame packet) => sent.add(packet);
  @override
  Stream<void> get done => const Stream.empty();
  @override
  Future<void> close() async {}
}

class _Path implements DatagramPath {
  final List<Uint8List> sent = [];
  @override
  bool healthy = true;
  @override
  bool send(Uint8List payload) {
    sent.add(payload);
    return true;
  }

  @override
  void close() {}
}

int _sequence = 0;
String _frameSession = 's';

RemoteInputPacketFrame _frame(
  RemoteInputEventType type,
  Map<String, Object> payload,
) => RemoteInputPacketFrame(
  sessionId: _frameSession,
  sequence: ++_sequence,
  timestampMicros: 0,
  eventType: type,
  payload: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
);

RemoteInputPacketFrame _move(num dx, num dy, {bool entry = false}) => _frame(
  RemoteInputEventType.mouseMove,
  {'deltaX': dx, 'deltaY': dy, 'activeStart': entry, 'buttons': 0},
);

RemoteInputPacketFrame _button(bool down) =>
    _frame(RemoteInputEventType.mouseButton, {'button': 0, 'down': down});

RemoteInputPacketFrame _key(bool down) =>
    _frame(RemoteInputEventType.key, {'macKeyCode': 0, 'down': down});

Map<String, dynamic> _payload(RemoteInputPacketFrame frame) =>
    jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;

/// A press, a drag, a release and a key, as a pointer crossing over would
/// send them. The pointer's position when each event that must not be
/// skipped was sent.
({List<RemoteInputPacketFrame> events, Map<int, (double, double)> at})
_session() {
  _sequence = 0;
  final events = <RemoteInputPacketFrame>[_move(0, 0, entry: true)];
  for (var i = 0; i < 10; i++) {
    events.add(_move(3, 1));
  }
  events.add(_button(true));
  for (var i = 0; i < 10; i++) {
    events.add(_move(-2, 4));
  }
  events.add(_button(false));
  for (var i = 0; i < 5; i++) {
    events.add(_move(1, 1));
  }
  events
    ..add(_key(true))
    ..add(_key(false));
  final at = <int, (double, double)>{};
  var x = 0.0, y = 0.0;
  for (final event in events) {
    if (event.eventType == RemoteInputEventType.mouseMove) {
      x += (_payload(event)['deltaX'] as num).toDouble();
      y += (_payload(event)['deltaY'] as num).toDouble();
    }
    if (isFencedInput(event)) at[event.sequence] = (x, y);
  }
  return (events: events, at: at);
}

void main() {
  test(
    'whatever is lost, repeated or late, the receiver applies every event '
    'once, in order, with the pointer where it was when the event was sent',
    () {
      // Each scenario turns what went by each way into the order it arrives.
      final scenarios =
          <
            String,
            List<RemoteInputPacketFrame> Function(
              List<RemoteInputPacketFrame> socket,
              List<RemoteInputPacketFrame> lane,
              Random random,
            )
          >{
            'all datagrams, then the socket': (socket, lane, _) => [
              ...lane,
              ...socket,
            ],
            'socket first, datagrams late': (socket, lane, _) => [
              ...socket,
              ...lane,
            ],
            'a third of the datagrams lost, socket late': (socket, lane, _) => [
              for (var i = 0; i < lane.length; i++)
                if (i % 3 != 1) lane[i],
              ...socket,
            ],
            'every datagram lost': (socket, _, _) => socket,
            'datagrams shuffled, interleaved with the socket':
                (socket, lane, random) {
                  final shuffled = [...lane]..shuffle(random);
                  final out = <RemoteInputPacketFrame>[];
                  var s = 0, l = 0;
                  while (s < socket.length || l < shuffled.length) {
                    final takeSocket =
                        l >= shuffled.length ||
                        (s < socket.length && random.nextInt(4) == 0);
                    out.add(takeSocket ? socket[s++] : shuffled[l++]);
                  }
                  return out;
                },
          };
      for (final MapEntry(key: name, value: arrive) in scenarios.entries) {
        for (var seed = 0; seed < 8; seed++) {
          final (:events, :at) = _session();
          final socket = _Socket();
          final path = _Path();
          final sender = RemoteInputLaneTransport(
            socket,
            path,
            repeats: const [],
            trailing: const Duration(days: 1),
          );
          for (final event in events) {
            sender.send(event);
          }
          unawaited(sender.close());
          final lane = [
            for (final bytes in path.sent) RemoteInputPacketFrame.decode(bytes),
          ];
          // Twice by UDP for good measure: copies must not count twice.
          final arrivals = arrive(socket.sent, [
            ...lane,
            ...lane,
          ], Random(seed));

          final applied = <RemoteInputPacketFrame>[];
          final merger = RemoteInputLaneMerger(applied.add);
          arrivals.forEach(merger.accept);

          var x = 0.0, y = 0.0, last = 0;
          final fenced = <int>[];
          for (final packet in applied) {
            expect(packet.sequence, greaterThanOrEqualTo(last), reason: name);
            last = packet.sequence;
            if (packet.eventType == RemoteInputEventType.mouseMove) {
              x += (_payload(packet)['deltaX'] as num).toDouble();
              y += (_payload(packet)['deltaY'] as num).toDouble();
            }
            if (isFencedInput(packet)) {
              fenced.add(packet.sequence);
              expect((x, y), at[packet.sequence], reason: '$name #$seed');
            }
          }
          expect(fenced, at.keys.toList(), reason: '$name #$seed');
        }
      }
    },
  );

  test('a move whose button is still on its way waits for it', () {
    final (:events, at: _) = _session();
    final socket = _Socket();
    final path = _Path();
    final sender = RemoteInputLaneTransport(socket, path, repeats: const []);
    for (final event in events) {
      sender.send(event);
    }
    unawaited(sender.close());
    final lane = [
      for (final bytes in path.sent) RemoteInputPacketFrame.decode(bytes),
    ];
    final down = events.firstWhere(
      (e) => e.eventType == RemoteInputEventType.mouseButton,
    );
    final applied = <RemoteInputPacketFrame>[];
    final merger = RemoteInputLaneMerger(applied.add);
    // Every datagram but the button's copy; the button comes by the socket
    // last, as after a retransmission.
    for (final packet in lane) {
      if (packet.sequence != down.sequence) merger.accept(packet);
    }
    final dragged = applied.where((p) => p.sequence > down.sequence);
    expect(dragged, isEmpty);
    socket.sent.forEach(merger.accept);
    expect(
      applied.indexWhere((p) => p.sequence == down.sequence),
      lessThan(applied.indexWhere((p) => p.sequence > down.sequence)),
    );
  });

  test('moves go by UDP while it answers and by the socket when it does '
      'not; what must not be skipped always goes by the socket', () {
    _sequence = 0;
    final socket = _Socket();
    final path = _Path();
    final sender = RemoteInputLaneTransport(socket, path, repeats: const []);
    sender
      ..send(_move(0, 0, entry: true))
      ..send(_move(1, 0));
    path.healthy = false;
    sender
      ..send(_move(1, 0))
      ..send(_button(true));
    unawaited(sender.close());
    expect(socket.sent.map((p) => p.sequence), [1, 3, 4]);
    expect(path.sent.map((b) => RemoteInputPacketFrame.decode(b).sequence), [
      1,
      2,
    ]);
  });

  test('a packet without a stamp, from an older sender, passes through', () {
    _sequence = 0;
    final applied = <RemoteInputPacketFrame>[];
    final merger = RemoteInputLaneMerger(applied.add);
    final plain = [_move(0, 0, entry: true), _move(5, 5), _move(5, 5)];
    plain.forEach(merger.accept);
    expect(applied, plain);
  });

  test(
    'over real sockets: an accepted offer names a UDP port, the session '
    'gets the lane, moves go by it and everything arrives in order',
    () async {
      const sessionId = '22222222-2222-4222-8222-222222222222';
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      await RemoteInputDatagrams.open();
      addTearDown(RemoteInputDatagrams.close);
      final tokens = SessionUpgradeTokenRegistry();
      final manager = RemoteInputManager();
      final offer = manager.createOffer(
        sourcePeerId: 'source',
        sinkPeerId: 'sink',
        layoutEdge: RemoteInputEdge.right,
        releaseHotkey: '',
      );
      expect(offer.datagrams, isTrue);
      final accept = manager.acceptOffer(
        RemoteInputControlMessage.fromJson({
          ...offer.toJson(),
          'sessionId': sessionId,
        }),
      );
      // As it goes on the wire, once the server adds the upgrade token.
      final wire = accept.withTransportToken('t').toJson();
      expect(
        RemoteInputControlMessage.fromJson(wire).datagramPort,
        RemoteInputDatagrams.endpoint!.port,
      );
      // What an older sink answers: no port, so the WebSocket only.
      expect(
        RemoteInputControlMessage.fromJson(
          wire..remove('datagramPort'),
        ).datagramPort,
        0,
      );

      final applied = <RemoteInputPacketFrame>[];
      manager.onPacket = applied.add;
      final server = WsSvrManager.forTesting(
        remoteInputManager: manager,
        sessionUpgradeTokens: tokens,
        // No chat connection in this test to tie the media session to.
        mediaPeerClaimValidator: (_) => true,
        manageSharedCoordinators: false,
      );
      final started = await server.startServer(0);
      addTearDown(
        () => server.closeGracefully(closeServer: true, forceServerClose: true),
      );
      final token = tokens.issue(
        route: '/input',
        sessionId: sessionId,
        peerId: 'source',
        mediaMacKey: key,
        now: DateTime.now(),
      );
      final transport = await RemoteInputWebSocketPacketTransport.connect(
        buildPeerPacketUri(
          host: '127.0.0.1',
          port: started.port,
          path: '/input',
          queryParameters: {'session': sessionId, 'token': token},
        ),
        mediaMacKey: key,
        accept: accept,
      );
      addTearDown(transport.close);
      expect(transport, isA<RemoteInputLaneTransport>());
      final lane = transport as RemoteInputLaneTransport;
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (!lane.laneHealthy) {
        if (DateTime.now().isAfter(deadline)) fail('the lane never answered');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      _frameSession = sessionId;
      addTearDown(() => _frameSession = 's');
      final (:events, :at) = _session();
      events.forEach(transport.send);
      while (applied.isEmpty || applied.last.sequence < events.last.sequence) {
        if (DateTime.now().isAfter(deadline)) fail('not everything arrived');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(lane.movesByLane, greaterThan(0));
      var x = 0.0, y = 0.0;
      final fenced = <int>[];
      for (final packet in applied) {
        if (packet.eventType == RemoteInputEventType.mouseMove) {
          x += (_payload(packet)['deltaX'] as num).toDouble();
          y += (_payload(packet)['deltaY'] as num).toDouble();
        }
        if (isFencedInput(packet)) {
          fenced.add(packet.sequence);
          expect((x, y), at[packet.sequence]);
        }
      }
      expect(fenced, at.keys.toList());
    },
  );
}
