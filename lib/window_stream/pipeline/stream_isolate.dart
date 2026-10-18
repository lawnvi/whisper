import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:sodium/sodium.dart';
import 'package:window_stream_native/window_stream_native.dart';

import '../../socket/aead_engine.dart';

import '../android/scrcpy/scrcpy_stream_worker.dart';
import '../core/window_input_event.dart';
import '../core/window_source.dart';
import '../core/window_stream_models.dart';
import 'media_sink.dart';
import '../remote/remote_window_worker.dart';
import 'native_input_decoder.dart';
import 'stream_worker.dart';
import 'texture_surface.dart';

/// Event from the stream isolate about one stream.
class StreamIsolateEvent {
  const StreamIsolateEvent(this.streamId, this.event);

  final String streamId;
  final StreamTransportEvent event;
}

/// The UI isolate's handle on the stream isolate, which reads every stream's
/// media sockets and pushes packets into native surfaces, and receives window
/// input directly from native code.
class StreamIsolate {
  StreamIsolate._(this._isolate, this._commands, this._events, this._receive);

  final Isolate _isolate;
  final SendPort _commands;
  final StreamController<StreamIsolateEvent> _events;
  final ReceivePort _receive;

  Stream<StreamIsolateEvent> get events => _events.stream;

  static Future<StreamIsolate> spawn() async {
    final receive = ReceivePort('window-stream');
    final events = StreamController<StreamIsolateEvent>.broadcast();
    final ready = Completer<SendPort>();
    receive.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is StreamIsolateEvent) {
        events.add(message);
      }
    });
    final isolate = await Isolate.spawn(
      _streamIsolateMain,
      _IsolateStart(receive.sendPort, RootIsolateToken.instance),
      debugName: 'window-stream',
    );
    final commands = await ready.future;
    return StreamIsolate._(isolate, commands, events, receive);
  }

  void attach({
    required String streamId,
    required int surface,
    required StreamTransportSpec spec,
    ScrollMode scrollMode = ScrollMode.wheel,
  }) {
    _commands.send(_Attach(streamId, surface, spec, scrollMode));
  }

  void detach(String streamId) => _commands.send(_Detach(streamId));

  void control(String streamId, Uint8List bytes) {
    _commands.send(_Control(streamId, bytes));
  }

  void input(String streamId, WindowInputEvent event) {
    _commands.send(_Input(streamId, event));
  }

  void setScrollMode(String streamId, ScrollMode mode) {
    _commands.send(_SetScrollMode(streamId, mode));
  }

  Future<void> dispose() async {
    _commands.send(const _Shutdown());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _isolate.kill(priority: Isolate.beforeNextEvent);
    _receive.close();
    await _events.close();
  }
}

class _Attach {
  const _Attach(this.streamId, this.surface, this.spec, this.scrollMode);

  final String streamId;
  final int surface;
  final StreamTransportSpec spec;
  final ScrollMode scrollMode;
}

class _Detach {
  const _Detach(this.streamId);

  final String streamId;
}

class _Control {
  const _Control(this.streamId, this.bytes);

  final String streamId;
  final Uint8List bytes;
}

class _Input {
  const _Input(this.streamId, this.event);

  final String streamId;
  final WindowInputEvent event;
}

class _SetScrollMode {
  const _SetScrollMode(this.streamId, this.mode);

  final String streamId;
  final ScrollMode mode;
}

class _Shutdown {
  const _Shutdown();
}

class _IsolateStart {
  const _IsolateStart(this.main, this.token);

  final SendPort main;
  final RootIsolateToken? token;
}

Future<void> _streamIsolateMain(_IsolateStart start) async {
  final token = start.token;
  if (token != null) {
    // Lets the isolate reach platform channels (texture decoders on mobile).
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  }
  try {
    // AEAD acceleration is per isolate; without it /window falls back to the
    // much slower pure-Dart cipher.
    WhisperAead.installNativeAcceleration(await SodiumInit.init());
  } catch (_) {
    // Pure-Dart fallback still works.
  }
  final main = start.main;
  final runtime = _StreamRuntime(main);
  final receive = ReceivePort();
  main.send(receive.sendPort);
  receive.listen((message) {
    switch (message) {
      case _Attach():
        runtime.attach(message);
      case _Detach():
        runtime.detach(message.streamId);
      case _Control():
        runtime.workers[message.streamId]?.control(message.bytes);
      case _Input():
        runtime.workers[message.streamId]?.input(message.event);
      case _SetScrollMode():
        runtime.workers[message.streamId]?.setScrollMode(message.mode);
      case _Shutdown():
        runtime.shutdown();
        receive.close();
    }
  });
}

class _StreamRuntime {
  _StreamRuntime(this._main) {
    if (Platform.isAndroid || Platform.isIOS) {
      _sink = TextureFrameSink();
      return;
    }
    final bindings = WindowStreamNativeBindings.load();
    _bindings = bindings;
    if (bindings != null) {
      _sink = NativeMediaSink(bindings);
      _inputCallable = NativeCallable<WsnInputCallbackNative>.listener(
        _onNativeInput,
      );
      bindings.setInputCallback(_inputCallable!.nativeFunction);
    }
  }

  final SendPort _main;
  WindowStreamNativeBindings? _bindings;
  MediaSink? _sink;
  NativeCallable<WsnInputCallbackNative>? _inputCallable;
  final workers = <String, StreamWorker>{};
  final _streamBySurface = <int, String>{};

  void _emit(String streamId, StreamTransportEvent event) {
    _main.send(StreamIsolateEvent(streamId, event));
  }

  void attach(_Attach command) {
    final sink = _sink;
    if (sink == null) {
      _emit(
        command.streamId,
        const TransportEnded(
          failure: WindowStreamFailure(
            WindowStreamFailureReason.nativeUnavailable,
          ),
        ),
      );
      return;
    }
    final StreamWorker worker = switch (command.spec) {
      ScrcpySocketsSpec spec => ScrcpyStreamWorker(
        surface: command.surface,
        spec: spec,
        sink: sink,
        scrollMode: command.scrollMode,
        emit: (event) => _emit(command.streamId, event),
      ),
      WhisperWindowSpec spec => RemoteWindowWorker(
        surface: command.surface,
        spec: spec,
        sink: sink,
        emit: (event) => _emit(command.streamId, event),
      ),
    };
    workers[command.streamId] = worker;
    _streamBySurface[command.surface] = command.streamId;
    unawaited(worker.start());
  }

  void detach(String streamId) {
    final worker = workers.remove(streamId);
    _streamBySurface.removeWhere((_, id) => id == streamId);
    unawaited(worker?.close());
  }

  void _onNativeInput(
    int surface,
    int kind,
    int code,
    int modifiers,
    double x,
    double y,
    double dx,
    double dy,
    int phase,
    Pointer<Char> text,
  ) {
    final decodedText = _bindings?.takeText(text);
    final streamId = _streamBySurface[surface];
    if (streamId == null) {
      return;
    }
    final event = NativeInputDecoder.decode(
      kind: kind,
      code: code,
      modifiers: modifiers,
      x: x,
      y: y,
      dx: dx,
      dy: dy,
      phase: phase,
      text: decodedText,
    );
    if (event != null) {
      workers[streamId]?.input(event);
    }
  }

  void shutdown() {
    for (final worker in workers.values) {
      unawaited(worker.close());
    }
    workers.clear();
    _streamBySurface.clear();
    // Native code must stop calling before the trampoline goes away.
    _bindings?.setInputCallback(nullptr);
    _inputCallable?.close();
    _inputCallable = null;
  }
}
