import 'package:desktop_multi_window/desktop_multi_window.dart';

/// The main engine has one handler for what its other windows call: the tray
/// panel and the screenshot overlay share it, by method.
abstract final class MainWindowCalls {
  static final _handlers = <String, Future<void> Function(Object?)>{};
  static bool _installed = false;

  static void on(String method, Future<void> Function(Object? arguments) f) {
    _handlers[method] = f;
    if (_installed) return;
    _installed = true;
    WindowController.fromCurrentEngine().then(
      (me) => me.setWindowMethodHandler((call) async {
        await _handlers[call.method]?.call(call.arguments);
        return null;
      }),
    );
  }
}
