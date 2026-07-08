import 'dart:async';
import 'dart:io';

import 'package:whisper/audio/audio_group_coordinator.dart';
import 'package:whisper/audio/audio_platform.dart';
import 'package:whisper/helper/notification_l10n.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/socket/svrmanager.dart';

/// 把播放端(sink)状态镜像到系统媒体外壳,并把媒体控制意图
/// 转回协调器。只读状态、只转发意图,不触碰播放数据通路。
class AudioMediaSessionBridge {
  static final AudioMediaSessionBridge _instance =
      AudioMediaSessionBridge._internal();

  factory AudioMediaSessionBridge() => _instance;

  AudioMediaSessionBridge._internal();

  AudioGroupCoordinator? _coordinator;
  AudioPlatform? _platform;
  bool _rejoining = false;
  Timer? _rejoinTimeout;
  String _lastState = 'stopped';

  AppLocalizations get _l10n => resolveNotificationL10n();

  void attach({
    required AudioGroupCoordinator coordinator,
    required AudioPlatform platform,
  }) {
    if (!Platform.isAndroid) {
      return;
    }
    _coordinator?.removeListener(_sync);
    _coordinator = coordinator;
    _platform = platform;
    platform.onMediaControl = _handleControl;
    coordinator.addListener(_sync);
  }

  void _handleControl(String action) {
    final coordinator = _coordinator;
    if (coordinator == null) {
      return;
    }
    switch (action) {
      case 'pause':
      case 'focusPause':
      case 'focusPauseTransient':
        // buffering(rejoin 在途)中暂停 = 取消在途 rejoin:
        // 复位 rejoining 让媒体卡立即回落 paused,而不是卡在 buffering。
        _rejoining = false;
        _rejoinTimeout?.cancel();
        coordinator.pausePlaybackAsSink();
        _sync();
        break;
      case 'resume':
      case 'focusResume':
        _rejoining = true;
        _sync();
        coordinator.requestRejoinAsSink().then((sent) {
          if (!sent) {
            _rejoining = false;
            _sync();
          }
        });
        // spec 错误处理:重加入失败不许卡死在 buffering。
        // 10 秒内源端未 re-offer(isPlaybackActive 仍为 false)则回落 paused,
        // 媒体卡上的"播放"按钮即为重试入口。
        _rejoinTimeout?.cancel();
        _rejoinTimeout = Timer(const Duration(seconds: 10), () {
          if (_rejoining && !(_coordinator?.isPlaybackActive ?? false)) {
            _rejoining = false;
            _sync();
          }
        });
        break;
      case 'disconnect':
        // 与 pause 同理:buffering(rejoin 在途)中断开 = 放弃在途 rejoin,
        // 复位后媒体卡立即回落,而不是僵持 buffering 直到 10s 超时。
        _rejoining = false;
        _rejoinTimeout?.cancel();
        coordinator.disconnectPlaybackAsSink();
        _sync();
        break;
    }
  }

  bool _sourceSupportsRejoin(String sourcePeerId) {
    if (sourcePeerId.isEmpty) {
      return false;
    }
    return WsSvrManager()
            .remoteProfileFor(sourcePeerId)
            ?.capabilities
            .audioGroupRejoinV1 ==
        true;
  }

  String _sourceTitle(String sourcePeerId) {
    if (sourcePeerId.isEmpty) {
      return 'Whisper';
    }
    final deviceName =
        WsSvrManager().remoteProfileFor(sourcePeerId)?.device.name.trim();
    if (deviceName != null && deviceName.isNotEmpty) {
      return deviceName;
    }
    return sourcePeerId;
  }

  void _sync() {
    final coordinator = _coordinator;
    final platform = _platform;
    if (coordinator == null || platform == null) {
      return;
    }
    final String state;
    if (coordinator.isPlaybackActive) {
      state = 'playing';
      _rejoining = false;
    } else if (_rejoining && !coordinator.canRejoinAsSink) {
      // rejoin 上下文已被清除(源端停组/本端断开):在途 rejoin 不可能
      // 完成,立即回落而不是渲染 buffering 等 10s 超时。
      _rejoining = false;
      _rejoinTimeout?.cancel();
      state = 'stopped';
    } else if (_rejoining) {
      state = 'buffering';
    } else if (coordinator.canRejoinAsSink) {
      state = 'paused';
    } else {
      state = 'stopped';
    }
    if (state == _lastState && state != 'playing') {
      return;
    }
    _lastState = state;
    final l10n = _l10n;
    final sessionSourcePeerId = coordinator.session?.sourcePeerId ?? '';
    final sourcePeerId = sessionSourcePeerId.isNotEmpty
        ? sessionSourcePeerId
        : coordinator.rejoinSourcePeerId;
    platform.updateMediaState(
      state: state,
      title: _sourceTitle(sourcePeerId),
      subtitle: l10n.audioPlaybackNotificationSubtitle,
      canResume:
          coordinator.canRejoinAsSink && _sourceSupportsRejoin(sourcePeerId),
      pauseLabel: l10n.mediaActionPause,
      playLabel: l10n.mediaActionPlay,
      disconnectLabel: l10n.mediaActionDisconnect,
      channelName: l10n.notificationChannelMedia,
    );
  }
}
