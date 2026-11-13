import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:whisper/socket/peer_socket_session.dart';
import 'package:whisper/socket/socket_admission.dart';

/// The most a peer may send before it has proved who it is. The largest
/// handshake message is 256 KiB, and a whole handshake is a few of them.
const int preAuthByteCap = 1024 * 1024;

/// A socket that is destroyed once more than [cap] bytes have arrived while
/// the peer is not yet trusted (see [liftWhen]).
///
/// dart:io's WebSocket gathers a whole message, however large, before anyone
/// can look at it, so a size check on messages comes too late: a peer that
/// has not authenticated could fill memory with a single message. Counting
/// here, below the WebSocket and HTTP layers, stops it after [cap] bytes.
final class PreAuthCappedSocket extends Stream<Uint8List> implements Socket {
  PreAuthCappedSocket(this._inner, {this.cap = preAuthByteCap, this.onEnd});

  final Socket _inner;
  final int cap;

  /// Called once when the connection is over: closed, failed or destroyed.
  final void Function()? onEnd;

  int _received = 0;
  bool _lifted = false;
  bool _ended = false;
  bool _cutOff = false;
  bool Function()? _trusted;

  /// Lets the connection carry any amount once [trusted] says so; it is asked
  /// when the cap is crossed. Until this is called, the cap holds.
  void liftWhen(bool Function() trusted) => _trusted = trusted;

  void _end() {
    if (_ended) {
      return;
    }
    _ended = true;
    onEnd?.call();
  }

  void _count(Uint8List data, EventSink<Uint8List> sink) {
    // Only a cut-off connection stops here. After this side's close() the
    // peer may still answer (a WebSocket close frame) and must be heard.
    if (_cutOff) {
      return;
    }
    if (!_lifted) {
      _received += data.length;
      if (_received > cap) {
        if (_trusted?.call() ?? false) {
          _lifted = true;
        } else {
          _cutOff = true;
          destroy();
          sink.close();
          return;
        }
      }
    }
    sink.add(data);
  }

  // Counted in a transformer rather than in the subscription's onData:
  // dart:io hands the subscription on after a WebSocket upgrade and replaces
  // its onData, which would skip a count kept there.
  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _inner
      .transform(
        StreamTransformer<Uint8List, Uint8List>.fromHandlers(
          handleData: _count,
          handleError: (error, stackTrace, sink) {
            if (!_cutOff) {
              sink.addError(error, stackTrace);
            }
          },
          handleDone: (sink) {
            _end();
            if (!_cutOff) {
              sink.close();
            }
          },
        ),
      )
      .listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  void destroy() {
    _end();
    _inner.destroy();
  }

  @override
  Future<void> close() async {
    try {
      await _inner.close();
    } finally {
      _end();
    }
  }

  @override
  Encoding get encoding => _inner.encoding;

  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> flush() => _inner.flush();

  @override
  void write(Object? object) => _inner.write(object);

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _inner.writeln(object);

  @override
  bool setOption(SocketOption option, bool enabled) =>
      _inner.setOption(option, enabled);

  @override
  Uint8List getRawOption(RawSocketOption option) => _inner.getRawOption(option);

  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);

  @override
  int get port => _inner.port;

  @override
  int get remotePort => _inner.remotePort;

  @override
  InternetAddress get address => _inner.address;

  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;
}

extension PreAuthLease on AdmissionLease {
  /// Ties this lease to the connection it admitted: evicting the lease
  /// destroys [socket], and its byte cap lifts once the peer authenticated.
  void bind(Socket socket) {
    evictWith(socket.destroy);
    if (socket is PreAuthCappedSocket) {
      socket.liftWhen(() => isAuthenticated);
    }
  }
}

/// Whether an incoming handshake may still be evicted for a newer one: only
/// before a valid proof. After it, a pairing prompt may be waiting for the
/// user, and legitimate handshakes get there within moments.
bool serverAwaitsProof(PeerSocketSession session) =>
    session.phase == PeerSocketPhase.awaitingHello ||
    session.phase == PeerSocketPhase.awaitingProof;

/// The WebSocket for a chat connection this device opened, capped until the
/// server is trusted: this side has approved it, so the server sends its
/// result and anything after only once [session] stands at awaitingResult.
WebSocket cappedClientWebSocket(
  Socket socket,
  PeerSocketSession? Function() session,
) {
  final capped = PreAuthCappedSocket(socket)
    ..liftWhen(() {
      final phase = session()?.phase;
      return phase == PeerSocketPhase.awaitingResult ||
          phase == PeerSocketPhase.authenticated;
    });
  return WebSocket.fromUpgradedSocket(capped, serverSide: false);
}
