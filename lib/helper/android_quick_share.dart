import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract class AndroidQuickSharePlatform {
  void setShareIntentHandler(Future<void> Function() handler);

  Future<List<String>> consumePendingShareUris();

  Future<List<String>> stageSharedUris(List<String> uriStrings);
}

class MethodChannelAndroidQuickSharePlatform
    implements AndroidQuickSharePlatform {
  const MethodChannelAndroidQuickSharePlatform({
    MethodChannel channel = const MethodChannel(
      'com.vireen.whisper/android_quick_share',
    ),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  void setShareIntentHandler(Future<void> Function() handler) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shareIntentReceived') {
        await handler();
      }
    });
  }

  @override
  Future<List<String>> consumePendingShareUris() async {
    if (!Platform.isAndroid) {
      return const <String>[];
    }
    final result = await _channel.invokeListMethod<String>(
      'consumePendingShareUris',
    );
    return result ?? const <String>[];
  }

  @override
  Future<List<String>> stageSharedUris(List<String> uriStrings) async {
    if (!Platform.isAndroid || uriStrings.isEmpty) {
      return const <String>[];
    }
    final result = await _channel.invokeListMethod<String>(
      'stageSharedUris',
      <String, Object>{'uris': uriStrings},
    );
    return result ?? const <String>[];
  }
}

class AndroidQuickShare extends ChangeNotifier {
  AndroidQuickShare({
    AndroidQuickSharePlatform platform =
        const MethodChannelAndroidQuickSharePlatform(),
  }) : _platform = platform {
    _platform.setShareIntentHandler(loadPendingShare);
  }

  static final AndroidQuickShare shared = AndroidQuickShare();

  final AndroidQuickSharePlatform _platform;
  List<String> _pendingFilePaths = const <String>[];

  bool get hasPendingShare => _pendingFilePaths.isNotEmpty;

  List<String> get pendingFilePaths =>
      List<String>.unmodifiable(_pendingFilePaths);

  Future<void> loadPendingShare() async {
    final uriStrings = await _platform.consumePendingShareUris();
    if (uriStrings.isEmpty) {
      clear();
      return;
    }
    final stagedPaths = await _platform.stageSharedUris(uriStrings);
    _pendingFilePaths = stagedPaths
        .where((path) => path.trim().isNotEmpty)
        .toList(growable: false);
    notifyListeners();
  }

  bool isConnectedTarget(String peerId, Set<String> connectedPeerIds) {
    return connectedPeerIds.contains(peerId);
  }

  void clear() {
    if (_pendingFilePaths.isEmpty) {
      return;
    }
    _pendingFilePaths = const <String>[];
    notifyListeners();
  }
}
