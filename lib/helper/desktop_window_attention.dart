import 'package:whisper/helper/helper.dart';
import 'package:window_manager/window_manager.dart';

Future<void> revealDesktopWindowForAttention() async {
  if (!isDesktop()) {
    return;
  }
  try {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
  } on Object {
    // The pairing dialog must remain available even if the window manager
    // rejects a foreground request on the current desktop session.
  }
}
