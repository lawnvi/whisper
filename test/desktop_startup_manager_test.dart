import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/desktop_startup.dart';

void main() {
  test('windows startup command quotes executable path', () {
    expect(
      buildWindowsStartupCommand(r'C:\Program Files\Whisper\whisper.exe'),
      r'"C:\Program Files\Whisper\whisper.exe" --hidden',
    );
  });
}
