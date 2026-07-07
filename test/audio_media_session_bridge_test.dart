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
    expect(bridge, contains("'buffering'")); // 重连中间态
    expect(bridge, contains('audioGroupRejoinV1')); // canResume 门控
    expect(bridge, contains('focusPauseTransient'));
    expect(platform, contains("'updateMediaState'"));
    expect(platform, contains('onMediaControl'));
    expect(manager, contains('PeerProfile? remoteProfileFor'));
    expect(main, contains('AudioMediaSessionBridge().attach'));
  });
}
