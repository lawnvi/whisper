import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// One button of a question asked while Whisper is in the background.
class IslandAskButton {
  const IslandAskButton(this.id, this.label, {this.role = 'neutral'});

  final String id;
  final String label;

  /// How it is coloured: `decline` (red), `accept` (green), `primary`
  /// (blue) or `neutral`.
  final String role;

  Map<String, Object> toJson() => {'id': id, 'label': label, 'role': role};
}

/// Questions for the user while Whisper is in the background (Android): a
/// device that wants to browse files, a window sent here. Each shows on the
/// island over other apps as an open card, and as a notification with the
/// same buttons (on the system's own island where it has one). The answer,
/// from either, comes back to the asker; `open` is the card or notification
/// itself tapped, which brings Whisper up to ask there.
class IslandAsks {
  IslandAsks._();

  static final IslandAsks shared = IslandAsks._();

  static const _channel = MethodChannel('com.vireen.whisper/island');
  static const open = 'open';

  final _answers = <String, void Function(String button)>{};
  bool _listening = false;

  Future<void> ask({
    required String id,
    required String glyph,
    required String title,
    required String text,
    required List<IslandAskButton> buttons,
    required String channelName,
    required void Function(String button) onAnswer,
    String figure = '',
    String? platform,
    Duration? timeout,
  }) async {
    if (!Platform.isAndroid) {
      return;
    }
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler(_onCall);
    }
    _answers[id] = onAnswer;
    try {
      await _channel.invokeMethod<bool>('ask', {
        'id': id,
        'glyph': glyph,
        'title': title,
        'text': text,
        'figure': figure,
        'platform': ?platform,
        'buttons': [for (final button in buttons) button.toJson()],
        'channelName': channelName,
        'timeoutMs': ?timeout?.inMilliseconds,
      });
    } on PlatformException {
      _answers.remove(id);
    } on MissingPluginException {
      _answers.remove(id);
    }
  }

  /// Answered elsewhere (in the app), or gone: away from the island and the
  /// notification shade.
  Future<void> settle(String id) async {
    if (_answers.remove(id) == null || !Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('settle', {'id': id});
    } on PlatformException {
      // Gone already.
    } on MissingPluginException {
      // Not on this platform.
    }
  }

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'answer') {
      return;
    }
    final arguments = Map<Object?, Object?>.from(call.arguments as Map);
    final id = arguments['id'] as String? ?? '';
    final button = arguments['button'] as String? ?? '';
    _answers.remove(id)?.call(button);
  }
}
