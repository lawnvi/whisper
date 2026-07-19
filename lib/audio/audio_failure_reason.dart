import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

enum AudioFailureReason {
  permission,
  unsupported,
  busy,
  captureIo,
  playbackIo,
  codec,
  transport,
  protocol,
  remoteFailure,
}

enum AudioFailureContext { capture, playback, protocol, transport }

AudioFailureReason audioFailureReasonFromWire(String value) {
  return switch (value) {
    'permission' => AudioFailureReason.permission,
    'unsupported' => AudioFailureReason.unsupported,
    'busy' => AudioFailureReason.busy,
    'captureIo' => AudioFailureReason.captureIo,
    'playbackIo' => AudioFailureReason.playbackIo,
    'codec' => AudioFailureReason.codec,
    'transport' => AudioFailureReason.transport,
    'protocol' => AudioFailureReason.protocol,
    'remoteFailure' => AudioFailureReason.remoteFailure,
    _ => AudioFailureReason.remoteFailure,
  };
}

AudioFailureReason audioFailureReasonFor(
  Object error, {
  required AudioFailureContext context,
}) {
  if (error is PlatformException) {
    final code = error.code.toLowerCase();
    if (code.contains('permission') || code.contains('denied')) {
      return AudioFailureReason.permission;
    }
    if (code.contains('unsupported') ||
        code.contains('unavailable') ||
        code.contains('not-supported')) {
      return AudioFailureReason.unsupported;
    }
    if (code.contains('busy') || code.contains('already-active')) {
      return AudioFailureReason.busy;
    }
    if (code.contains('codec') || code.contains('opus')) {
      return AudioFailureReason.codec;
    }
    if (code.contains('transport') ||
        code.contains('socket') ||
        code.contains('connect') ||
        code.contains('network')) {
      return AudioFailureReason.transport;
    }
    if (code.contains('capture')) {
      return AudioFailureReason.captureIo;
    }
    if (code.contains('playback')) {
      return AudioFailureReason.playbackIo;
    }
  }
  if (error is UnsupportedError) {
    return AudioFailureReason.unsupported;
  }
  if (error is TimeoutException ||
      error is SocketException ||
      error is HttpException ||
      error is HandshakeException) {
    return AudioFailureReason.transport;
  }
  if (error is FormatException) {
    return AudioFailureReason.protocol;
  }
  return switch (context) {
    AudioFailureContext.capture => AudioFailureReason.captureIo,
    AudioFailureContext.playback => AudioFailureReason.playbackIo,
    AudioFailureContext.protocol => AudioFailureReason.protocol,
    AudioFailureContext.transport => AudioFailureReason.transport,
  };
}
