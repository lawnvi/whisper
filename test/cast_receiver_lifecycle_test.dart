import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/cast_receiver/cast_receiver_manager.dart';

final _endpoint = (InternetAddress('192.168.1.2'), _Interface());

void main() {
  test(
    'disabled preference opens no receiver; toggle persists both ways',
    () async {
      final backend = _Backend();
      var saved = false;
      final receiver = CastReceiverManager(
        backend: backend,
        endpointResolver: () async => _endpoint,
        loadEnabled: () async => saved,
        saveEnabled: (value) async => saved = value,
      );
      await receiver.initialize();
      expect(backend.starts, 0);
      await receiver.setEnabled(true);
      expect(saved, isTrue);
      expect(receiver.status.state, CastReceiverState.running);
      await receiver.setEnabled(false);
      expect(saved, isFalse);
      expect(receiver.enabled, isFalse);
      expect(receiver.status.state, CastReceiverState.stopped);
      receiver.dispose();
    },
  );

  test('shutdown waits for startup and closes the receiver', () async {
    final endpoint = Completer<CastReceiverEndpoint?>();
    final backend = _Backend();
    final receiver = CastReceiverManager(
      backend: backend,
      endpointResolver: () => endpoint.future,
      saveEnabled: (_) async {},
    );
    final start = receiver.setEnabled(true);
    final stop = receiver.stop();
    expect(receiver.busy, isTrue);
    endpoint.complete(_endpoint);
    await Future.wait([start, stop]);
    expect(backend.starts, 1);
    expect(backend.stops, 1);
    expect(receiver.enabled, isFalse);
    expect(receiver.busy, isFalse);
    expect(receiver.status.state, CastReceiverState.stopped);
    receiver.dispose();
  });
}

class _Backend extends ReceiverBackend {
  bool fail = false;
  int starts = 0;
  int stops = 0;

  @override
  Future<void> start(CastReceiverEndpoint? endpoint) async {
    starts++;
    if (fail) throw StateError('unavailable');
    update(CastReceiverState.running);
  }

  @override
  Future<void> stop() async {
    stops++;
    update(CastReceiverState.stopped);
  }
}

class _Interface implements NetworkInterface {
  @override
  List<InternetAddress> get addresses => [InternetAddress('192.168.1.2')];
  @override
  int get index => 1;
  @override
  String get name => 'ethernet';
}
