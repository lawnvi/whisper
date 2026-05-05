import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/desktop_startup.dart';

void main() {
  test('linux autostart desktop entry launches the executable', () {
    final entry = buildLinuxAutostartDesktopEntry(
      appName: 'Whisper',
      executablePath: '/opt/Whisper/whisper desktop',
    );

    expect(entry, contains('[Desktop Entry]'));
    expect(entry, contains('Name=Whisper'));
    expect(entry, contains('Exec="/opt/Whisper/whisper desktop"'));
    expect(entry, contains('X-GNOME-Autostart-enabled=true'));
  });

  test('macOS launch agent opens the app bundle on login', () {
    final plist = buildMacOSLaunchAgentPlist(
      label: 'com.vireen.whisper.launch-at-login',
      appPath: '/Applications/Whisper.app',
    );

    expect(
        plist, contains('<string>com.vireen.whisper.launch-at-login</string>'));
    expect(plist, contains('<string>/usr/bin/open</string>'));
    expect(plist, contains('<string>/Applications/Whisper.app</string>'));
    expect(plist, isNot(contains('<string>-a</string>')));
    expect(plist, contains('<key>RunAtLoad</key>'));
  });

  test('macOS app path is derived from bundled executable path', () {
    expect(
      macOSAppPathFromExecutable(
        '/Applications/Whisper.app/Contents/MacOS/whisper',
      ),
      '/Applications/Whisper.app',
    );
    expect(macOSAppPathFromExecutable('/tmp/whisper'), '/tmp/whisper');
  });

  test('windows startup command quotes executable path', () {
    expect(
      buildWindowsStartupCommand(r'C:\Program Files\Whisper\whisper.exe'),
      r'"C:\Program Files\Whisper\whisper.exe"',
    );
  });
}
