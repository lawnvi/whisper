import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

enum RemoteInputFailureReason {
  permission,
  unsupported,
  trustRequired,
  busy,
  capture,
  injection,
  transport,
  protocol,
  remoteFailure,
}

enum RemoteInputFailureContext { capture, injection, protocol, transport }

RemoteInputFailureReason remoteInputFailureReasonFromWire(String value) {
  return switch (value) {
    'permission' => RemoteInputFailureReason.permission,
    'unsupported' => RemoteInputFailureReason.unsupported,
    'trustRequired' => RemoteInputFailureReason.trustRequired,
    'busy' => RemoteInputFailureReason.busy,
    'capture' => RemoteInputFailureReason.capture,
    'injection' => RemoteInputFailureReason.injection,
    'transport' => RemoteInputFailureReason.transport,
    'protocol' => RemoteInputFailureReason.protocol,
    'remoteFailure' => RemoteInputFailureReason.remoteFailure,
    _ => RemoteInputFailureReason.remoteFailure,
  };
}

RemoteInputFailureReason remoteInputFailureReasonFor(
  Object error, {
  required RemoteInputFailureContext context,
}) {
  if (error is PlatformException) {
    final code = error.code.toLowerCase();
    if (code.contains('permission') || code.contains('denied')) {
      return RemoteInputFailureReason.permission;
    }
    if (code.contains('unsupported') ||
        code.contains('unavailable') ||
        code.contains('not-supported')) {
      return RemoteInputFailureReason.unsupported;
    }
    if (code.contains('trust')) {
      return RemoteInputFailureReason.trustRequired;
    }
    if (code.contains('busy') || code.contains('already-active')) {
      return RemoteInputFailureReason.busy;
    }
    if (code.contains('transport') ||
        code.contains('socket') ||
        code.contains('connect') ||
        code.contains('network')) {
      return RemoteInputFailureReason.transport;
    }
    if (code.contains('capture')) {
      return RemoteInputFailureReason.capture;
    }
    if (code.contains('inject')) {
      return RemoteInputFailureReason.injection;
    }
  }
  if (error is UnsupportedError) {
    return RemoteInputFailureReason.unsupported;
  }
  if (error is TimeoutException ||
      error is SocketException ||
      error is HttpException ||
      error is HandshakeException) {
    return RemoteInputFailureReason.transport;
  }
  if (error is FormatException) {
    return RemoteInputFailureReason.protocol;
  }
  return switch (context) {
    RemoteInputFailureContext.capture => RemoteInputFailureReason.capture,
    RemoteInputFailureContext.injection => RemoteInputFailureReason.injection,
    RemoteInputFailureContext.protocol => RemoteInputFailureReason.protocol,
    RemoteInputFailureContext.transport => RemoteInputFailureReason.transport,
  };
}
