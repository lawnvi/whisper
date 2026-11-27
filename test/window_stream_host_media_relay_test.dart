import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/remote/host_media_relay.dart';

/// The host media isolate seals video for a `/window` socket only the main
/// isolate holds. Its queue skips frames when the socket is slow, so a
/// write must complete only once the socket took it; and when the viewer
/// goes away the stream must end at once, not after a writer timeout.
void main() {
  late _Socket socket;
  late RelayedWriter writer;
  late List<ReceivePort> ports;

  setUp(() {
    socket = _Socket();
    final toMain = ReceivePort();
    final toIsolate = ReceivePort();
    ports = [toMain, toIsolate];
    writer = RelayedWriter(1, toMain.sendPort.send);
    final sink = RelayedSink(1, socket, toIsolate.sendPort.send);
    toMain.listen((message) => sink.take(message as RelayWrite));
    toIsolate.listen((message) => writer.answer(message as RelayAck));
  });

  tearDown(() {
    for (final port in ports) {
      port.close();
    }
  });

  Future<void> write(int byte) =>
      writer.addStream(Stream<Object>.value(Uint8List.fromList([byte])));

  test(
    'writes finish when the socket took them, in order, then close',
    () async {
      var firstDone = false;
      final first = write(1).then((_) => firstDone = true);
      await pumpEventQueue();
      expect(socket.written, [
        [1],
      ]);
      expect(firstDone, isFalse);
      socket.takeNext();
      await first;
      final second = write(2);
      await pumpEventQueue();
      socket.takeNext();
      await second;
      await writer.close();
      expect(socket.written, [
        [1],
        [2],
      ]);
      expect(socket.closed, isTrue);
    },
  );

  test(
    'a socket that goes away fails the waiting write and later ones',
    () async {
      final stuck = write(1);
      await pumpEventQueue();
      socket.drop();
      await expectLater(stuck, throwsA(isA<RelayedSocketGone>()));
      await expectLater(write(2), throwsA(isA<RelayedSocketGone>()));
      expect(socket.written, [
        [1],
      ]);
    },
  );
}

/// A `/window` socket whose writes finish when the test says so.
class _Socket implements StreamSink<dynamic> {
  final written = <List<int>>[];
  final _gates = <Completer<void>>[];
  final _done = Completer<void>();
  bool closed = false;

  @override
  Future<void> addStream(Stream<dynamic> stream) async {
    await for (final chunk in stream) {
      written.add(List<int>.of(chunk as List<int>));
    }
    final gate = Completer<void>();
    _gates.add(gate);
    await gate.future;
  }

  void takeNext() => _gates.removeAt(0).complete();

  /// The viewer went away.
  void drop() {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> close() async {
    closed = true;
    drop();
  }

  @override
  Future<void> get done => _done.future;

  @override
  void add(dynamic data) => throw UnimplementedError();

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      throw UnimplementedError();
}
