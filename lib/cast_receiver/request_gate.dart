import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:whisper/helper/desktop_window_attention.dart';

class CastRequest {
  CastRequest(this.address);
  final String address;
  int secondsRemaining = 5;
  final result = Completer<bool>();
}

/// Decisions last only while reception stays enabled; an IP is not an identity.
class CastRequestGate extends ChangeNotifier {
  CastRequestGate({this.onRequest});
  static final shared = CastRequestGate(
    onRequest: () => unawaited(revealDesktopWindowForAttention()),
  );
  final VoidCallback? onRequest;
  final _allowed = <String>{};
  final _denied = <String>{};
  bool _open = false;
  Timer? _timer;
  Timer? _presentationTimeout;
  CastRequest? _pending;
  CastRequest? get pending => _pending;

  void open() {
    close();
    _open = true;
  }

  Future<bool> authorize(String address) {
    if (!_open || _denied.contains(address)) return Future.value(false);
    if (_allowed.contains(address)) return Future.value(true);
    final current = _pending;
    if (current != null) {
      return current.address == address
          ? current.result.future
          : Future.value(false);
    }
    final request = _pending = CastRequest(address);
    // A hidden window may not produce the frame needed to mount the prompt.
    onRequest?.call();
    _presentationTimeout = Timer(
      const Duration(seconds: 10),
      () => decide(request, false),
    );
    notifyListeners();
    return request.result.future;
  }

  /// Begin the countdown only after the prompt is mounted and shown.
  void presented(CastRequest request) {
    if (!identical(request, _pending) || _timer != null) return;
    _presentationTimeout?.cancel();
    _presentationTimeout = null;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (--request.secondsRemaining <= 0) {
        decide(request, true);
      } else {
        notifyListeners();
      }
    });
  }

  void decide(CastRequest request, bool allowed) {
    if (!identical(request, _pending)) return;
    (allowed ? _allowed : _denied).add(request.address);
    _finish(allowed);
  }

  bool cancel(String address) {
    if (_pending?.address != address) return false;
    _finish(false);
    return true;
  }

  void _finish(bool allowed) {
    _timer?.cancel();
    _timer = null;
    _presentationTimeout?.cancel();
    _presentationTimeout = null;
    final request = _pending;
    _pending = null;
    request?.result.complete(allowed);
    notifyListeners();
  }

  void close() {
    _open = false;
    _allowed.clear();
    _denied.clear();
    _finish(false);
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}
