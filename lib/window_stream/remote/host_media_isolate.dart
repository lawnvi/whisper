import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';
import 'package:window_stream_native/window_stream_native.dart';

import '../../audio/audio_codec.dart';
import '../../socket/aead_engine.dart';
import 'host_audio.dart';
import 'host_media_relay.dart';
import 'host_stream_media.dart';

/// The desktop host's media isolate. Native code hands it every capture's
/// video packets and sound (`wsn_set_capture_media_callback`); it codes the
/// sound, seals the packets and passes them to the main isolate, which only
/// writes them to the `/window` sockets it holds ([RelayedSink]). The
/// host's UI isolate stays free while windows stream.
///
/// The main isolate points native code at the isolate's callback and takes
/// it away again ([route]): never before the isolate is up, and the moment
/// it is gone.
class HostMediaIsolate {
  HostMediaIsolate._(this._commands, this._receive, this._route);

  /// Null when the isolate did not come up (or native code can't route
  /// media), and the host keeps its media in the main isolate.
  static Future<HostMediaIsolate?> spawn({
    required void Function(int? callbackAddress) route,
    required void Function() onExit,
  }) async {
    final receive = ReceivePort('window-host-media');
    final exit = ReceivePort();
    final ready = Completer<(SendPort, int)?>();
    HostMediaIsolate? planes;
    receive.listen((message) {
      if (!ready.isCompleted) {
        ready.complete(message is (SendPort, int) ? message : null);
      } else {
        planes?._handle(message);
      }
    });
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _hostMediaMain,
        receive.sendPort,
        debugName: 'window-host-media',
        errorsAreFatal: false,
        onExit: exit.sendPort,
      );
    } catch (_) {
      isolate = null;
    }
    final started = isolate == null
        ? null
        : await ready.future.timeout(
            const Duration(seconds: 5),
            onTimeout: () => null,
          );
    if (started == null) {
      isolate?.kill(priority: Isolate.immediate);
      receive.close();
      exit.close();
      return null;
    }
    final (commands, callback) = started;
    final created = planes = HostMediaIsolate._(commands, receive, route);
    exit.listen((_) {
      exit.close();
      created._exited();
      onExit();
    });
    route(callback);
    return created;
  }

  final SendPort _commands;
  final ReceivePort _receive;
  final void Function(int? callbackAddress) _route;
  final _links = <int, _IsolatePlane>{};
  int _nextLink = 0;

  /// [sink] is the stream's `/window` socket; the seal's keys go to the
  /// isolate and are wiped here.
  HostMediaPlane open(
    StreamSink<dynamic> sink,
    HostMediaSeal seal, {
    required void Function(String reason) onEnded,
  }) {
    final link = ++_nextLink;
    final plane = _links[link] = _IsolatePlane(
      this,
      link,
      RelayedSink(link, sink, _commands.send),
      onEnded,
    );
    try {
      _commands.send(_Open(link, seal));
    } finally {
      seal.wipe();
    }
    return plane;
  }

  void _handle(Object? message) {
    switch (message) {
      case RelayWrite(:final link):
        final plane = _links[link];
        if (plane == null) {
          _commands.send(RelayAck(link, 0, ok: false));
        } else {
          plane.sink.take(message);
        }
      case _Ended(:final link, :final reason):
        _links[link]?.onEnded(reason);
      case _Counts(:final link, :final counts):
        _links[link]?.counts = counts;
      case _Closed(:final link):
        final closed = _links[link]?.closed;
        if (closed != null && !closed.isCompleted) closed.complete();
    }
  }

  void _exited() {
    _route(null);
    _receive.close();
    final planes = _links.values.toList(growable: false);
    _links.clear();
    for (final plane in planes) {
      plane.sink.fail();
      if (!plane.closed.isCompleted) plane.closed.complete();
      plane.onEnded('mediaIsolateExited');
    }
  }
}

/// A stream whose media is in the isolate. Video and sound never pass
/// through here: native code gives them to the isolate.
class _IsolatePlane implements HostMediaPlane {
  _IsolatePlane(this._owner, this.link, this.sink, this.onEnded);

  final HostMediaIsolate _owner;
  final int link;
  final RelayedSink sink;
  final void Function(String reason) onEnded;
  final closed = Completer<void>();
  bool _closing = false;

  @override
  HostMediaCounts counts = const HostMediaCounts();

  void _send(Object message) => _owner._commands.send(message);

  @override
  void start(int capture) => _send(_Start(link, capture));

  @override
  void video(
    Uint8List payload, {
    required int ptsUs,
    required bool config,
    required bool key,
  }) {}

  @override
  void audio(
    Uint8List pcm, {
    required int ptsUs,
    required int rate,
    required int channels,
  }) {}

  @override
  void control(Uint8List packet) => _send(_Control(link, packet));

  @override
  set audioOpen(bool open) => _send(_Gate(link, open));

  /// What was queued goes out first; a socket that takes nothing more is
  /// closed here after a few seconds.
  @override
  Future<void> close() async {
    if (!_closing) {
      _closing = true;
      _send(_Close(link));
    }
    await closed.future.timeout(const Duration(seconds: 3), onTimeout: () {});
    _owner._links.remove(link);
    await sink.closeSocket();
  }
}

final class _Open {
  const _Open(this.link, this.seal);

  final int link;
  final HostMediaSeal seal;
}

final class _Start {
  const _Start(this.link, this.capture);

  final int link;
  final int capture;
}

final class _Gate {
  const _Gate(this.link, this.open);

  final int link;
  final bool open;
}

final class _Control {
  const _Control(this.link, this.packet);

  final int link;
  final Uint8List packet;
}

final class _Close {
  const _Close(this.link);

  final int link;
}

final class _Ended {
  const _Ended(this.link, this.reason);

  final int link;
  final String reason;
}

final class _Counts {
  const _Counts(this.link, this.counts);

  final int link;
  final HostMediaCounts counts;
}

final class _Closed {
  const _Closed(this.link);

  final int link;
}

Future<void> _hostMediaMain(SendPort main) async {
  try {
    // Per isolate; without it every packet is sealed in pure Dart.
    WhisperAead.installNativeAcceleration(await SodiumInit.init());
  } catch (_) {
    // The pure-Dart cipher still works.
  }
  final native = WindowStreamNativeBindings.load();
  if (native == null || native.setCaptureMediaCallback == null) {
    main.send(false);
    return;
  }
  HostAudioEncoder.openCodec = (config) async =>
      OpusAudioCodec.createInWorker(config);
  final runtime = _HostMediaRuntime(main, native);
  final commands = ReceivePort();
  commands.listen(runtime.handle);
  main.send((commands.sendPort, runtime.callback.nativeFunction.address));
}

class _HostMediaRuntime {
  _HostMediaRuntime(this._main, this._native) {
    Timer.periodic(const Duration(seconds: 1), (_) {
      for (final link in _links.values) {
        _main.send(_Counts(link.id, link.media.counts));
      }
    });
  }

  final SendPort _main;
  final WindowStreamNativeBindings _native;
  final _links = <int, _Link>{};
  final _byCapture = <int, _Link>{};
  late final callback = NativeCallable<WsnCaptureCallbackNative>.listener(
    _onCapture,
  );

  void handle(Object? message) {
    switch (message) {
      case RelayAck(:final link):
        _links[link]?.writer.answer(message);
      case _Open(:final link, :final seal):
        _open(link, seal);
      case _Start(:final link, :final capture):
        final entry = _links[link];
        if (entry != null) {
          entry.capture = capture;
          _byCapture[capture] = entry;
          entry.media.start(capture);
        }
      case _Gate(:final link, :final open):
        _links[link]?.media.audioOpen = open;
      case _Control(:final link, :final packet):
        _links[link]?.media.control(packet);
      case _Close(:final link):
        _close(link);
    }
  }

  void _open(int link, HostMediaSeal seal) {
    final writer = RelayedWriter(link, _main.send);
    final entry = _links[link] = _Link(link, writer);
    entry.media = HostStreamMedia.sealed(
      addStream: writer.addStream,
      closeSink: writer.close,
      seal: seal,
      setBusy: (busy) {
        final capture = entry.capture;
        if (capture != null) _native.captureSetBusy(capture, busy ? 1 : 0);
      },
      askKeyframe: () => entry.askKeyframe(_native),
      onEnded: (reason) => _main.send(_Ended(link, reason)),
    );
  }

  void _close(int link) {
    final entry = _links.remove(link);
    if (entry == null) {
      _main.send(_Closed(link));
      return;
    }
    _byCapture.remove(entry.capture);
    unawaited(
      entry.media
          .close()
          .catchError((Object _) {})
          .whenComplete(() => _main.send(_Closed(link))),
    );
  }

  void _onCapture(
    int id,
    int kind,
    Pointer<Uint8> data,
    int length,
    int ptsUs,
    int flags,
    int width,
    int height,
  ) {
    final bytes = _native.takeBytes(data, length);
    final entry = _byCapture[id];
    if (entry == null) {
      return;
    }
    switch (kind) {
      case WsnCaptureEvent.packet:
        entry.media.video(
          bytes,
          ptsUs: ptsUs,
          config: flags & WsnPacket.config != 0,
          key: flags & WsnPacket.key != 0,
        );
      case WsnCaptureEvent.audio:
        entry.media.audio(bytes, ptsUs: ptsUs, rate: width, channels: height);
    }
  }
}

class _Link {
  _Link(this.id, this.writer);

  final int id;
  final RelayedWriter writer;
  late final HostStreamMedia media;
  int? capture;
  final _sinceAsk = Stopwatch();

  /// At most every 250 ms, as the host asks.
  void askKeyframe(WindowStreamNativeBindings native) {
    final capture = this.capture;
    if (capture == null ||
        (_sinceAsk.isRunning && _sinceAsk.elapsedMilliseconds < 250)) {
      return;
    }
    _sinceAsk
      ..reset()
      ..start();
    native.captureRequestKeyframe(capture);
  }
}
