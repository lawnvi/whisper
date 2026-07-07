import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('conversation prompts use AppLocalizations', () {
    final source = File('lib/page/conversation.dart').readAsStringSync();

    for (final text in [
      '排队中',
      '准备续传',
      '协商中',
      '等待重连',
      '已暂停',
      '校验中',
      '失败，可重试',
      '已取消',
      '采集端：正在连接远端扬声器',
      '播放端：正在准备播放共享声音',
      '采集端：正在共享本机声音，点击停止',
      '播放端：正在作为扬声器播放，点击停止',
      '共享本机声音到此设备',
      '已停止播放共享声音',
      '已停止共享声音',
      '当前设备不支持系统音频采集',
      '正在请求对端播放本机声音',
      '共享声音失败',
      '键鼠共享：正在连接对端',
      '键鼠共享：正在准备接收控制',
      '键鼠共享：边缘穿越已启用，点击停止',
      '键鼠共享：正在控制对端，点击停止',
      '键鼠共享：正在接收控制，点击停止',
      '启用键鼠共享',
      '已停止键鼠共享',
      '请先停止当前键鼠共享会话',
      '当前设备不支持键鼠共享',
      '当前连接设备不支持键鼠共享',
      '键鼠共享需要互信设备',
      '请先在设备设置里把对端屏幕贴到本机边缘',
      '键鼠共享已启用，移动到屏幕边缘开始控制对端',
      '键鼠共享失败',
    ]) {
      expect(source, isNot(contains("'$text")));
      expect(source, isNot(contains('"$text')));
    }

    expect(source, isNot(contains("tooltip: '重试'")));
    expect(source, isNot(contains("tooltip: '取消'")));

    expect(source, contains('l10n.audioShareStart'));
    expect(source, contains('l10n.audioShareFailed('));
    expect(source, contains('l10n.remoteInputStart'));
    expect(source, contains('l10n.remoteInputFailed('));
  });

  test('audio sharing start prompt names the peer as the destination', () {
    final zhArb = File('lib/l10n/app_zh.arb').readAsStringSync();

    expect(
      zhArb,
      isNot(contains('"audioShareStart": "共享本机声音到此设备"')),
    );
    expect(zhArb, contains('"audioShareStart": "把本机声音共享给对端"'));
  });
}
