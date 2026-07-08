import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/android_background.dart';

void main() {
  test('keep alive notification serializes progress for native Android', () {
    const notification = AndroidKeepAliveNotification(
      title: 'Whisper',
      description: 'Sending file 42%',
      progress: 42,
    );

    final arguments = notification.toChannelArguments();
    expect(arguments['title'], 'Whisper');
    expect(arguments['description'], 'Sending file 42%');
    expect(arguments['progress'], 42);
    expect(arguments['indeterminateProgress'], false);
    // channel 名/描述取自 l10n(测试环境回落 en),仅断言非空透传。
    expect(arguments['channelName'], isNotEmpty);
    expect(arguments['channelDescription'], isNotEmpty);
  });

  test('keep alive notification clamps progress to Android bounds', () {
    const notification = AndroidKeepAliveNotification(
      title: 'Whisper',
      description: 'Sending file',
      progress: 142,
      indeterminateProgress: true,
    );

    expect(notification.toChannelArguments()['progress'], 100);
    expect(notification.toChannelArguments()['indeterminateProgress'], true);
  });
}
