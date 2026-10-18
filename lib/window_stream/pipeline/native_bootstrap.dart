import 'package:window_stream_native/window_stream_native.dart';

/// Loads the native library for the UI isolate and clears native state left
/// by a previous Dart run (hot restart) exactly once, so every owner of a
/// native callback (viewer windows, local capture) can initialise in any
/// order without wiping each other's callbacks.
abstract final class WindowStreamNativeBootstrap {
  static bool _reset = false;

  static WindowStreamNativeBindings? bindings() {
    final bindings = WindowStreamNativeBindings.load();
    if (bindings != null && !_reset) {
      _reset = true;
      bindings.resetAll();
    }
    return bindings;
  }
}
