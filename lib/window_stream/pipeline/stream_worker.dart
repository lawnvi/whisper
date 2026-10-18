import 'dart:typed_data';

import '../core/window_input_event.dart';

/// One stream's transport inside the stream isolate. Each
/// [StreamTransportSpec] type has its own implementation.
abstract interface class StreamWorker {
  Future<void> start();

  /// Input from the window (or from automation), already decoded.
  void input(WindowInputEvent event);

  /// Raw protocol bytes built by the UI isolate (start app, reset video…).
  void control(Uint8List bytes);

  void setScrollMode(ScrollMode mode);

  Future<void> close();
}
