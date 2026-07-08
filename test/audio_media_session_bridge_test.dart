import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // 状态映射与门控是纯逻辑,用 source 断言 + 纯函数单测双保险。
  test('media session bridge maps coordinator state and gates resume', () {
    final bridge =
        File('lib/audio/audio_media_session.dart').readAsStringSync();
    final platform = File('lib/audio/audio_platform.dart').readAsStringSync();
    final manager = File('lib/socket/svrmanager.dart').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    expect(bridge, contains('pausePlaybackAsSink'));
    expect(bridge, contains('requestRejoinAsSink'));
    expect(bridge, contains('disconnectPlaybackAsSink'));
    expect(bridge, contains('coordinator.rejoinSourcePeerId'));
    expect(bridge, contains("'buffering'")); // 重连中间态
    expect(bridge, contains('audioGroupRejoinV1')); // canResume 门控
    expect(bridge, contains('focusPauseTransient'));
    expect(platform, contains("'updateMediaState'"));
    expect(platform, contains('onMediaControl'));
    expect(manager, contains('PeerProfile? remoteProfileFor'));
    expect(main, contains('AudioMediaSessionBridge().attach'));
  });

  test('buffering resets on every rejoin-cancelling path, not only pause', () {
    final bridge =
        File('lib/audio/audio_media_session.dart').readAsStringSync();

    String section(String startMarker, String endMarker) {
      final start = bridge.indexOf(startMarker);
      expect(start, greaterThanOrEqualTo(0), reason: '未找到: $startMarker');
      final end = bridge.indexOf(endMarker, start);
      expect(end, greaterThan(start), reason: '未找到终点: $endMarker');
      return bridge.substring(start, end);
    }

    // disconnect 与 pause 同理:buffering(rejoin 在途)中断开 = 放弃在途
    // rejoin,必须复位 _rejoining/超时器,否则媒体卡僵持 buffering 直到
    // 10s 超时才回落。
    final disconnect = section("case 'disconnect':", 'break;');
    expect(disconnect, contains('_rejoining = false;'));
    expect(disconnect, contains('_rejoinTimeout?.cancel();'));

    // 源端在 rejoin 在途时停组(rejoin 上下文被清):在途 rejoin 不可能
    // 完成,_sync 不得继续渲染 buffering。
    final sync = section('void _sync()', 'platform.updateMediaState');
    expect(sync, contains('_rejoining && !coordinator.canRejoinAsSink'));
  });
}
