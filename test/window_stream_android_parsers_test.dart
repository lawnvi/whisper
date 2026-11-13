import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/window_stream/adb/adb_host_client.dart';
import 'package:whisper/window_stream/android/android_device_props.dart';
import 'package:whisper/window_stream/android/android_task_list.dart';
import 'package:whisper/window_stream/android/scrcpy/scrcpy_compat_source.dart';

void main() {
  test('am stack list: tasks carry their display and base component', () {
    const output = '''
RootTask id=421 bounds=[0,0][1080,2400] displayId=18 userId=0
  taskId=421: com.kylin.read/com.dragon.read.pages.splash.SplashActivity bounds=[0,0][1080,2400] userId=0 visible=true topActivity=ComponentInfo{com.kylin.read/com.dragon.read.pages.main.MainFragmentActivity}
 configuration={1.0 460mcc1mnc [zh_CN] port}
RootTask id=1 bounds=[0,0][1220,2656] displayId=0 userId=0
  taskId=2: com.miui.home/.launcher.Launcher bounds=[0,0][1220,2656] userId=0 visible=false topActivity=ComponentInfo{com.miui.home/.launcher.Launcher}
''';
    final tasks = AndroidTaskList.parse(output);
    expect(tasks, hasLength(2));
    expect(tasks[0].taskId, 421);
    expect(tasks[0].packageName, 'com.kylin.read');
    expect(
      tasks[0].component,
      'com.kylin.read/com.dragon.read.pages.splash.SplashActivity',
    );
    expect(tasks[0].displayId, 18);
    expect(tasks[0].visible, isTrue);
    expect(tasks[1].displayId, 0);
    expect(tasks[1].visible, isFalse);
  });

  test('dumpsys activities: front task per display, top to bottom', () {
    const output = '''
Display #12 (activities from top to bottom):
  * Task{1a75de4 #17542 type=standard A=10300:com.phoenix.read U=0 visible=true}
Display #0 (activities from top to bottom):
  * Task{d06dc25 #1 type=home ?? U=0 visible=true}
  * Task{547dcae #16617 type=standard A=1000:com.android.settings.root U=0 visible=false}
''';
    final phone = AndroidTaskList.parseFrontTask(output)!;
    expect(phone.taskId, 1);
    expect(phone.isHome, isTrue);
    expect(
      AndroidTaskList.parseFrontTask(output, displayId: 12)!.taskId,
      17542,
    );
    expect(AndroidTaskList.parseFrontTask(output, displayId: 5), isNull);
  });

  test('device props: hashes the serial and adds the resolved launcher', () {
    final props = AndroidDeviceProps.parse(
      '33\n13\nOnePlus\nIN2010\n\nSERIAL123\ncom.example.launcher/.Home\n',
      serial: 'usb-serial',
    );
    expect(props.sdk, 33);
    expect(props.release, '13');
    expect(props.displayName, 'IN2010');
    expect(props.stableId, startsWith('android-'));
    expect(props.stableId, isNot(contains('SERIAL123')));
    expect(props.homePackages, contains('com.example.launcher'));
    expect(props.homePackages, contains('com.miui.home'));
    expect(props.isXiaomi, isFalse);
  });

  test('scrcpy list_apps output: labels with spaces, system marker', () {
    const output = '''
[server] INFO: Device: [Xiaomi] Xiaomi 25113PN0EC (Android 17)
[server] INFO: List of apps:
 * 开关控制                           com.google.android.accessibility.switchaccess
 - whisper                        com.vireen.whisper
 - Google Play 商店               com.android.vending
 - 红果免费漫剧                         com.kylin.read
''';
    final apps = ScrcpyCompatSource.parseAppList(output);
    expect(
      apps.map((a) => a.id),
      containsAll(['com.kylin.read', 'com.android.vending']),
    );
    final play = apps.firstWhere((a) => a.id == 'com.android.vending');
    expect(play.label, 'Google Play 商店');
    expect(
      apps.firstWhere((a) => a.id.contains('switchaccess')).system,
      isTrue,
    );
    expect(apps.firstWhere((a) => a.id == 'com.kylin.read').label, '红果免费漫剧');
  });

  // Bug: a label of 30 or more characters puts the package on the next line,
  // and its last word ("x;reboot;.y") became the id that `am force-stop` ran.
  test('scrcpy list_apps output: labels never become ids', () {
    final next = ' ' * 34;
    final cases = <String, Map<String, String>>{
      ' - A label long enough to wrap, ending x;reboot;.y\n'
          '${next}com.example.real\n'
          ' - whisper                        com.vireen.whisper\n': {
        'com.example.real': 'A label long enough to wrap, ending x;reboot;.y',
        'com.vireen.whisper': 'whisper',
      },
      ' * Thirty or more characters, then com.fake.app\n'
          '${next}com.example.real\n': {
        'com.example.real': 'Thirty or more characters, then com.fake.app',
      },
      ' - Evil                           x;reboot;.y\n'
              ' - Bare                           nodots\n':
          {},
    };
    for (final MapEntry(key: output, value: expected) in cases.entries) {
      final apps = ScrcpyCompatSource.parseAppList(output);
      expect({for (final app in apps) app.id: app.label}, expected);
    }
  });

  // Bug: the activity in front (named by whichever app it is) and app ids
  // went into `adb shell` as they were, running commands as the shell user.
  test('only components and package names reach the phone shell, quoted', () {
    final home = ScrcpyCompatSource.restoreFrontCommand(null);
    expect(home, contains('android.intent.category.HOME'));
    final restore = <String, String>{
      'com.kylin.read/com.dragon.read.pages.splash.SplashActivity':
          "am start -n 'com.kylin.read/com.dragon.read.pages.splash.SplashActivity' -f 0x10200000",
      r'com.miui.home/.launcher.Launcher$Alias':
          r"am start -n 'com.miui.home/.launcher.Launcher$Alias' -f 0x10200000",
      r'com.evil/com.evil.A;echo${IFS}hi|sh;': home,
      "com.evil/.A'x": home,
      'com.evil': home,
    };
    for (final MapEntry(key: component, value: command) in restore.entries) {
      expect(ScrcpyCompatSource.restoreFrontCommand(component), command);
    }
    final stop = <String, String?>{
      'com.kylin.read': "am force-stop 'com.kylin.read'",
      'x;reboot;.y': null,
      'com.evil;reboot': null,
      r'com.evil$(reboot)': null,
      '': null,
    };
    for (final MapEntry(key: appId, value: command) in stop.entries) {
      expect(ScrcpyCompatSource.forceStopCommand(appId), command);
    }
    expect(shellQuote("it's"), r"'it'\''s'");
  });
}
