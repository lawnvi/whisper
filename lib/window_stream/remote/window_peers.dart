import 'dart:typed_data';

import '../core/window_stream_models.dart';
import 'remote_peer_source.dart';
import 'window_stream_control.dart';

/// A Whisper peer connected now, as far as windows go.
class WindowStreamPeer {
  const WindowStreamPeer({
    required this.peerId,
    required this.name,
    required this.platform,
    required this.takesWindows,
  });

  final String peerId;
  final String name;
  final WindowStreamPlatform platform;

  /// It shows windows sent to it ("送到"): an iPad only does that.
  final bool takesWindows;

  bool sameAs(WindowStreamPeer other) =>
      peerId == other.peerId &&
      name == other.name &&
      platform == other.platform &&
      takesWindows == other.takesWindows;
}

/// One window another device sent to this one.
class WindowOffer {
  WindowOffer({
    required this.source,
    required this.window,
    this.thumbnail,
    this.icon,
  }) : receivedAt = DateTime.now();

  static const lifetime = Duration(minutes: 2);

  final RemotePeerSource source;
  final RemoteWindowInfo window;
  final Uint8List? thumbnail;

  /// The app's icon, for when the window can't be pictured (minimized).
  final Uint8List? icon;
  final DateTime receivedAt;

  /// Opens it like any other window of that device.
  OpenTarget get target => OpenTask(
    TaskEntry(
      id: window.id,
      appId: window.appId,
      label: window.title.isEmpty || window.title == window.appName
          ? window.appName
          : '${window.appName} — ${window.title}',
    ),
  );
}
