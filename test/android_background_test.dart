import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/android_background.dart';

void main() {
  test('keep alive notification serializes progress for native Android', () {
    const notification = AndroidKeepAliveNotification(
      title: 'Whisper',
      description: 'Sending file 42%',
      progress: 42,
    );

    expect(notification.toChannelArguments(), <String, Object?>{
      'title': 'Whisper',
      'description': 'Sending file 42%',
      'progress': 42,
      'indeterminateProgress': false,
    });
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
