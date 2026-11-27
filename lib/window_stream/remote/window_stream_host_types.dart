import 'dart:typed_data';

import 'window_stream_control.dart';

/// Sends a control message to a peer; returns false when it could not.
typedef WindowStreamControlSender =
    Future<bool> Function(WindowStreamControlMessage message);

/// Runs [action] with this device's media send key for [peerId].
typedef MediaSendKeyScope =
    T? Function<T>(String peerId, T Function(Uint8List key) action);

/// For a viewer connected now: runs [action] with the address its Whisper
/// session came from or went to, whether this device dialled that session,
/// and this device's media keys for the viewer. Null when not connected.
typedef MediaDialScope =
    T? Function<T>(
      String peerId,
      T Function(
        String host,
        bool dialledSession,
        Uint8List sendKey,
        Uint8List receiveKey,
      )
      action,
    );

enum HostStreamState { awaitingMedia, live, closed }

/// The kind of screen a viewer shows windows on, from its `open`.
enum WindowStreamViewerKind {
  phone,
  tablet,
  desktop;

  /// Viewers before `viewerKind` existed were phones or tablets (a Mac
  /// viewer then also shared one display per viewer).
  static WindowStreamViewerKind? parse(Object? value) =>
      value is String ? values.asNameMap()[value] : null;
}
