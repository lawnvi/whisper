import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/paste_island/paste_island_app.dart';
import 'package:whisper/new_ui/shell/shell_island.dart';
import 'package:whisper/remote_input/remote_clipboard_paste_watch.dart';
import 'package:whisper/widget/island/island_activity.dart';
import 'package:whisper/widget/island/island_center.dart';
import 'package:whisper/new_ui/shell/shell_device_page.dart';
import 'package:whisper/new_ui/shell/device_row_status.dart';
import 'package:whisper/new_ui/shell/shell_data.dart';
import 'package:whisper/new_ui/shell/shell_palette.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/new_ui/shell/whisper_shell.dart';
import 'package:whisper/new_ui/tray/tray_model.dart';
import 'package:whisper/new_ui/tray/tray_panel.dart';
import 'package:whisper/state/chat_session_list.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/new_ui/settings/settings_controls.dart';
import 'package:whisper/new_ui/shell/shell_device_drop.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/whisper_window.dart';
import 'package:whisper/widget/context_menu_region.dart';

import '../support/golden_support.dart';

DeviceData _device(String uid, String name, String platform, {int id = 1}) =>
    DeviceData(
      id: id,
      uid: uid,
      name: name,
      host: '192.168.31.8',
      port: 10002,
      platform: platform,
      isServer: false,
      online: true,
      clipboard: true,
      auth: true,
      lastTime: 0,
    );

ChatSessionItem _session(
  DeviceData device, {
  bool connected = false,
  bool nearby = false,
  String preview = '',
}) => ChatSessionItem(
  device: device,
  latestMessage: null,
  preview: preview,
  lastTimestamp: 0,
  isConnected: connected,
  isNearby: nearby,
  hasHistory: true,
  avatarLabel: device.name.substring(0, 1),
);

final _sessions = [
  _session(_device('imac', 'iMac', 'macos', id: 1), connected: true),
  _session(
    _device('tp', 'ThinkPad X1 Carbon 办公', 'windows', id: 2),
    connected: true,
    preview: 'http://192.168.31.8:10003/k7qm',
  ),
  _session(
    _device('mi', 'Xiaomi 16', 'android', id: 3),
    connected: true,
    preview: '收到',
  ),
  _session(_device('pad', 'Redmi Pad', 'android', id: 4), nearby: true),
  _session(_device('ub', 'Ubuntu', 'linux', id: 5)),
  _session(_device('px', 'Pixel 6', 'android', id: 7)),
];

ShellActions _actions(
  Widget Function(BuildContext, DeviceData) chat, {
  Widget card = const SizedBox.shrink(),
}) => ShellActions(
  select: (_) {},
  connect: (_) {},
  disconnect: (_) {},
  openPairing: ({bool startWithAddress = false}) async {},
  removeDevice: (_) async {},
  sendDropped: (_, _) {},
  contextActions: (_, {openCard}) => const <ContextMenuActionItem>[],
  openSound: () {},
  openInput: () {},
  openShareLinks: () {},
  openSettings: () {},
  openDiagnostics: (_) {},
  buildConversation: chat,
  buildFiles: (_, _) => const SizedBox.shrink(),
  buildApps: (_, _) => const SizedBox.shrink(),
  buildPlace: (_, _, _, {titleKey, controlsKey}) => const SizedBox.shrink(),
  buildSelfPanel: (_) => const SizedBox.shrink(),
  buildCard: (_, _, _) => card,
  paletteItems: (_) => const [],
  searchMessages: (_, _) async => const [],
);

ShellData _data({
  ShellPlace place = ShellPlace.device,
  String selected = 'imac',
}) => ShellData(
  self: _device('self', 'xiaoxin 的 MacBook Air 13 英寸', 'macos', id: 0),
  sessions: _sessions,
  selectedPeerId: selected,
  place: place,
  linksActive: true,
  factsFor: (s) {
    final id = s.device.uid;
    if (id == 'imac') {
      return const DeviceRowFacts(
        connected: true,
        transferName: 'log.txt',
        transferPercent: 59,
      );
    }
    return DeviceRowFacts(
      connected: s.isConnected,
      nearby: s.isNearby,
      paired: id != 'pad',
      preview: s.preview,
      offlineSince: id == 'ub' ? '昨天 22:14' : '9月12日',
    );
  },
  isPaired: (d) => d.uid != 'pad',
);

Widget _chat(BuildContext context, DeviceData device) => ListView(
  padding: const EdgeInsets.fromLTRB(16, 8, 16, 84),
  children: const [
    WhisperBubble(
      text: '发版说明改好了，帮我看一眼。主要动了挂载和共享链接两节，西语还没翻，你先看中文的就行。',
      mine: false,
      touch: false,
    ),
    SizedBox(height: 2),
    WhisperBubble(text: '不急', mine: false, touch: false),
    SizedBox(height: 8),
    WhisperBubble(text: '好', mine: true, touch: false),
  ],
);

Widget _app(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: brightness == Brightness.light
          ? AppTheme.lightTheme
          : AppTheme.darkTheme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: child,
    );

Future<void> _render(WidgetTester tester, String name) async {
  final out = Platform.environment['WHISPER_RENDER_OUT'];
  if (out == null) return;
  final boundary =
      tester.renderObject(find.byKey(const ValueKey('shot')))
          as RenderRepaintBoundary;
  final image = await tester.runAsync(() => boundary.toImage(pixelRatio: 2));
  final bytes = await tester.runAsync(
    () => image!.toByteData(format: ui.ImageByteFormat.png),
  );
  File('$out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  setUpAll(loadGoldenFonts);

  Future<void> pumpShell(
    WidgetTester tester,
    Size size, {
    Brightness brightness = Brightness.light,
    ShellPlace place = ShellPlace.device,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    WhisperWindow.hasMaterial.value = true;
    addTearDown(() => WhisperWindow.hasMaterial.value = false);
    await tester.pumpWidget(
      _app(
        RepaintBoundary(
          key: const ValueKey('shot'),
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFFB9D7FF), Color(0xFFF2C9EC)],
              ),
            ),
            child: WhisperShell(
              data: _data(place: place),
              actions: _actions(_chat),
            ),
          ),
        ),
        brightness: brightness,
      ),
    );
    await tester.pump(const Duration(seconds: 2));
  }

  group('the desktop shell', () {
    testWidgets('fits at the minimum window', (tester) async {
      await pumpShell(tester, const Size(720, 480));
      expect(tester.takeException(), isNull);
      expect(find.text('iMac'), findsWidgets);
      await _render(tester, 'shell-min');
    });

    testWidgets('long device names do not overflow', (tester) async {
      await pumpShell(tester, const Size(1144, 720));
      expect(tester.takeException(), isNull);
      expect(find.textContaining('ThinkPad'), findsOneWidget);
      await _render(tester, 'shell-light');
    });

    testWidgets('dark', (tester) async {
      await pumpShell(
        tester,
        const Size(1144, 720),
        brightness: Brightness.dark,
      );
      expect(tester.takeException(), isNull);
      await _render(tester, 'shell-dark');
    });

    testWidgets('the row says what is happening, in the accent colour', (
      tester,
    ) async {
      await pumpShell(tester, const Size(1144, 720));
      final text = tester.widget<Text>(find.text('log.txt 59%'));
      expect(text.style?.color, WhisperColors.light.accentText);
    });

    Finder infoButton() => find.byWidgetPredicate(
      (w) => w is ShellToolCapsuleItem && w.glyph == WhisperGlyph.info,
    );
    ShellDevicePage devicePage(WidgetTester tester) =>
        tester.widget<ShellDevicePage>(find.byType(ShellDevicePage));

    group('the device card follows its content', () {
      const body = ValueKey('card-body');
      Future<void> pumpCard(
        WidgetTester tester,
        Size size, {
        double height = 300,
      }) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _app(
            WhisperShell(
              data: _data(),
              actions: _actions(
                _chat,
                card: SingleChildScrollView(
                  child: SizedBox(key: body, height: height),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 2));
        await tester.tap(infoButton());
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
      }

      for (final (name, size) in const [
        ('wide', Size(1144, 720)),
        ('regular', Size(900, 640)),
      ]) {
        testWidgets('$name: floats over the content, as tall as it is', (
          tester,
        ) async {
          await pumpCard(tester, size);
          final card = tester.getRect(find.byKey(body));
          expect(card.size, const Size(296, 300));
          expect(card.right, size.width - 10);
          expect(card.top, 10);
          // Nothing under it moves.
          expect(
            tester.getRect(find.byType(ShellDevicePage)).right,
            size.width,
          );
        });
      }

      testWidgets('a click anywhere else closes it, and still does its job', (
        tester,
      ) async {
        var clicked = 0;
        tester.view.physicalSize = const Size(1144, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _app(
            WhisperShell(
              data: _data(),
              actions: _actions(
                (_, _) => Align(
                  alignment: Alignment.topLeft,
                  child: TextButton(
                    onPressed: () => clicked++,
                    child: const Text('IN THE CHAT'),
                  ),
                ),
                card: const SizedBox(height: 300),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 2));
        await tester.tap(infoButton());
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(devicePage(tester).cardOpen, isTrue);

        await tester.tap(find.text('IN THE CHAT'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(devicePage(tester).cardOpen, isFalse);
        expect(clicked, 1);
      });

      testWidgets('Esc closes it', (tester) async {
        await pumpCard(tester, const Size(1144, 720));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(devicePage(tester).cardOpen, isFalse);
      });

      testWidgets('choosing another device closes it, for good', (
        tester,
      ) async {
        await pumpCard(tester, const Size(1144, 720));
        Widget shell(String selected) => _app(
          WhisperShell(
            data: _data(selected: selected),
            actions: _actions(
              _chat,
              card: SingleChildScrollView(
                child: SizedBox(key: body, height: 300),
              ),
            ),
          ),
        );
        await tester.pumpWidget(shell('tp'));
        await tester.pump(const Duration(seconds: 2));
        expect(devicePage(tester).cardOpen, isFalse);
        expect(find.byKey(body), findsNothing);
        await tester.pumpWidget(shell('imac'));
        await tester.pump(const Duration(seconds: 2));
        expect(devicePage(tester).cardOpen, isFalse);
      });

      testWidgets('a short window scrolls inside the card', (tester) async {
        await pumpCard(tester, const Size(900, 480), height: 900);
        final scroll = tester.getRect(
          find
              .ancestor(
                of: find.byKey(body),
                matching: find.byType(SingleChildScrollView),
              )
              .first,
        );
        expect(scroll.bottom, 480 - 10);
        expect(tester.takeException(), isNull);
      });

      testWidgets('it steps aside for a place, and is there on the way back', (
        tester,
      ) async {
        await pumpCard(tester, const Size(1144, 720));
        final state = tester.state<State<StatefulWidget>>(
          find.byType(WhisperShell),
        );
        expect(state.mounted, isTrue);
        expect(find.byKey(body), findsOneWidget);
        await tester.pumpWidget(
          _app(
            WhisperShell(
              data: _data(place: ShellPlace.links),
              actions: _actions(
                _chat,
                card: SingleChildScrollView(
                  child: SizedBox(key: body, height: 300),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 2));
        expect(find.byKey(body).hitTestable(), findsNothing);
        await tester.pumpWidget(
          _app(
            WhisperShell(
              data: _data(),
              actions: _actions(
                _chat,
                card: SingleChildScrollView(
                  child: SizedBox(key: body, height: 300),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 2));
        expect(find.byKey(body), findsOneWidget);
      });
    });

    test('the sidebar starts with search', () {
      final source = File(
        'lib/new_ui/shell/shell_sidebar.dart',
      ).readAsStringSync();
      expect(
        source.indexOf('WhisperGlyph.search'),
        lessThan(source.indexOf('WhisperGlyph.speaker')),
      );
      expect(
        source.indexOf('WhisperGlyph.speaker'),
        lessThan(source.indexOf('WhisperGlyph.keyboard')),
      );
    });

    testWidgets('a page that is not about a device lets the sidebar go', (
      tester,
    ) async {
      await pumpShell(tester, const Size(1144, 720), place: ShellPlace.links);
      expect(tester.takeException(), isNull);
      expect(find.byType(LiquidSegmented<int>), findsNothing);
    });
  });

  group('the toolbar at its narrowest', () {
    for (final (name, connected) in [('connected', true), ('away', false)]) {
      for (final width in [468.0, 700.0]) {
        testWidgets('$name at $width, beside window buttons', (tester) async {
          tester.view.physicalSize = Size(width, 400);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final device = _device(
            'tp',
            'ThinkPad X1 Carbon 办公 很长的名字',
            'windows',
          );
          await tester.pumpWidget(
            _app(
              ShellDevicePage(
                session: _session(device, connected: connected),
                actions: _actions(_chat),
                paired: true,
                connecting: false,
                tab: 0,
                onTab: (_) {},
                cardOpen: false,
                onToggleCard: () {},
                rightInset: 138,
              ),
            ),
          );
          await tester.pump(const Duration(seconds: 1));
          // An overflow would have failed this already.
          expect(tester.takeException(), isNull);
          expect(
            find.byKey(const ValueKey('device-connection')),
            findsOneWidget,
          );
        });
      }
    }
  });

  group('recent clipboard in the tray', () {
    Future<List<Object?>> pumpTray(
      WidgetTester tester,
      List<TrayClip> clips,
    ) async {
      tester.view.physicalSize = const Size(420, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final actions = <Object?>[];
      await tester.pumpWidget(
        _app(
          Material(
            child: TrayPanelBody(
              state: TrayState(current: 'b', clips: clips),
              onAction: (action, [value]) => actions.add('$action:$value'),
            ),
          ),
        ),
      );
      await tester.pump();
      return actions;
    }

    const a = TrayClip(text: 'aaa', line: '这台 · 17:42');
    const b = TrayClip(text: 'b', line: '这台 · 17:44');

    testWidgets('it shows from the first thing copied', (tester) async {
      await pumpTray(tester, const []);
      expect(find.text('最近的剪贴板'), findsNothing);
      await pumpTray(tester, const [b]);
      expect(find.text('最近的剪贴板'), findsOneWidget);
    });

    testWidgets('pressing a row ticks it for a moment, and nothing moves', (
      tester,
    ) async {
      final actions = await pumpTray(tester, const [b, a]);
      final before = tester.getTopLeft(find.text('aaa'));
      await tester.tap(find.text('aaa'));
      await tester.pump();
      bool ticked() => find
          .byWidgetPredicate(
            (w) => w is WhisperIcon && w.glyph == WhisperGlyph.check,
          )
          .evaluate()
          .isNotEmpty;
      expect(actions, ['clipCopy:aaa']);
      expect(ticked(), isTrue);
      expect(tester.getTopLeft(find.text('aaa')), before);
      // It goes back to what it was.
      await tester.pump(const Duration(seconds: 1));
      expect(ticked(), isFalse);
    });
  });

  test('the device opened on stays when the list reorders', () {
    final list = File('lib/page/deviceList.dart').readAsStringSync();
    final getter = list.substring(
      list.indexOf('String? get _firstDesktopPeerId'),
      list.indexOf('DeviceRowFacts _shellFacts'),
    );
    expect(getter, contains('_openedOnPeerId'));
    expect(getter, isNot(contains('=>\n      _sessionItems.isEmpty')));
  });

  group('the tray panel on Windows', () {
    // media_kit_video keeps one static instance and replaces the top-level
    // window procedure. Registered again in the panel's engine, it sends the main
    // window's messages to the wrong place: WM_PAINT never ends and one core
    // stays at 100%.
    test('its engine does not register all the plugins again', () {
      final runner = File(
        'windows/runner/flutter_window.cpp',
      ).readAsStringSync();
      final callback = runner.substring(
        runner.indexOf('DesktopMultiWindowSetWindowCreatedCallback'),
        runner.indexOf('AudioSharePluginRegisterWithRegistrar'),
      );
      expect(callback, contains('WindowThemeTakeNextWindowIsPanel()'));
      expect(callback, contains('RegisterPanelPlugins('));
      final panel = runner.substring(
        runner.indexOf('void RegisterPanelPlugins('),
        runner.indexOf('}', runner.indexOf('void RegisterPanelPlugins(')),
      );
      expect(panel, isNot(contains('MediaKit')));
      expect(panel, contains('WindowManagerPluginRegisterWithRegistrar'));
    });

    test('the host says what the next window is, before creating it', () {
      final host = File('lib/new_ui/tray/tray_host.dart').readAsStringSync();
      final says = host.indexOf("'nextWindowIsPanel'");
      expect(says, greaterThan(-1));
      expect(says, lessThan(host.indexOf('WindowController.create')));
    });
  });

  group('the pieces over the window', () {
    test('the tray panel readies the Windows taskbar before leaving it', () {
      final source = File('lib/new_ui/tray/tray_panel.dart').readAsStringSync();
      final ready = source.indexOf('waitUntilReadyToShow()');
      expect(ready, greaterThan(-1));
      expect(ready, lessThan(source.indexOf('setSkipTaskbar(true)')));
    });

    Future<void> pumpOver(WidgetTester tester, Widget child, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          RepaintBoundary(
            key: const ValueKey('shot'),
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFFB9D7FF), Color(0xFFF2C9EC)],
                ),
              ),
              child: child,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
    }

    testWidgets('the tray panel, with everything in it', (tester) async {
      final actions = <String>[];
      await pumpOver(
        tester,
        Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: 340,
            child: Material(
              type: MaterialType.transparency,
              child: TrayPanelBody(
                state: const TrayState(
                  current: '发版说明改好了，帮我看一眼',
                  targets: [
                    TrayDevice(
                      id: 'imac',
                      name: 'iMac',
                      platform: 'macos',
                      order: 0,
                    ),
                    TrayDevice(
                      id: 'tp',
                      name: 'ThinkPad',
                      platform: 'windows',
                      order: 1,
                    ),
                    TrayDevice(
                      id: 'mi',
                      name: 'Xiaomi 16',
                      platform: 'android',
                      order: 2,
                    ),
                  ],
                  moments: [
                    TrayMoment(
                      id: 'a',
                      title: 'iMac 想浏览你的文件',
                      detail: '',
                      answers: ['允许', '拒绝'],
                    ),
                    TrayMoment(
                      id: 'b',
                      title: 'log.txt',
                      detail: '发到 iMac · 59%',
                      progress: .59,
                      cancelable: true,
                    ),
                  ],
                  soundOn: true,
                  soundStatus: '放到 iMac、Xiaomi 16',
                  inputStatus: '关',
                  flows: [
                    TrayFlow(
                      id: 'f',
                      title: '备忘录',
                      detail: '显示于 iMac',
                      action: '收回',
                    ),
                  ],
                  clips: [
                    TrayClip(
                      text: 'http://192.168.31.8:10003/k7qm',
                      line: '这台 · 17:42',
                    ),
                    TrayClip(text: '周报.pdf 的链接', line: 'iMac · 16:20'),
                  ],
                ),
                onAction: (action, [value]) => actions.add(action),
              ),
            ),
          ),
        ),
        const Size(420, 860),
      );
      expect(tester.takeException(), isNull);
      await _render(tester, 'tray');
      await tester.tap(find.text('iMac').first);
      await tester.tap(find.text('允许'));
      await tester.pump(const Duration(seconds: 1));
      expect(actions, containsAll(['send', 'answer']));
    });

    for (final (name, state) in [
      (
        'tray-empty',
        const TrayState(current: 'http://192.168.31.8:10003/k7qm'),
      ),
      (
        'tray-nearby',
        const TrayState(
          current: 'http://192.168.31.8:10003/k7qm',
          nearby: [
            TrayDevice(id: 'a', name: 'iMac', platform: 'macos', order: 1),
            TrayDevice(
              id: 'b',
              name: 'Xiaomi 16',
              platform: 'android',
              order: 2,
            ),
          ],
          clips: [
            TrayClip(
              text: 'http://192.168.31.8:10003/k7qm',
              line: '这台 · 17:42',
            ),
          ],
        ),
      ),
    ]) {
      testWidgets('the tray with nothing connected: $name', (tester) async {
        await pumpOver(
          tester,
          SizedBox(
            width: 340,
            child: Material(
              type: MaterialType.transparency,
              child: SingleChildScrollView(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Radix.slate3,
                    borderRadius: BorderRadius.circular(WhisperRadius.tray),
                  ),
                  child: TrayPanelBody(
                    state: state,
                    onAction: (action, [value]) {},
                  ),
                ),
              ),
            ),
          ),
          const Size(420, 860),
        );
        expect(tester.takeException(), isNull);
        // The clipboard line is there either way: the same shape as with a target.
        expect(find.text('http://192.168.31.8:10003/k7qm'), findsWidgets);
        expect(find.text('剪贴板'), findsOneWidget);
        await _render(tester, name);
      });
    }

    testWidgets('licences start below the window buttons', (tester) async {
      await pumpOver(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              WhisperPageRoute<void>(
                builder: (_) =>
                    const WhisperUnderWindowButtons(child: LicensePage()),
              ),
            ),
            child: const Text('open'),
          ),
        ),
        const Size(900, 700),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      // What the page's app bar goes by, to start below the status bar.
      expect(
        MediaQuery.paddingOf(tester.element(find.byType(LicensePage))).top,
        greaterThanOrEqualTo(WhisperUnderWindowButtons.inset),
      );
    });

    testWidgets('the about sheet, a row pressed', (tester) async {
      await pumpOver(
        tester,
        Center(
          child: SizedBox(
            width: 380,
            child: Material(
              color: Radix.white,
              child: SettingsScope(
                touch: false,
                page: false,
                child: SettingsAboutSheet(
                  icon: const SizedBox(height: 64),
                  name: 'Whisper',
                  description: '局域网协作',
                  version: '版本 0.0.58',
                  doneLabel: '完成',
                  links: [
                    ('官方网站', () {}),
                    ('GitHub 源代码', () {}),
                    ('查看许可', () {}),
                  ],
                ),
              ),
            ),
          ),
        ),
        const Size(480, 500),
      );
      final finger = await tester.startGesture(
        tester.getCenter(find.text('官方网站')),
      );
      await tester.pump(const Duration(seconds: 1));
      await _render(tester, 'about-pressed');
      await finger.cancel();
    });

    testWidgets('the drop sheet', (tester) async {
      final dir = Directory.systemTemp.createTempSync('drop');
      addTearDown(() => dir.deleteSync(recursive: true));
      final doc = File('${dir.path}/发版说明.pdf')
        ..writeAsBytesSync(List.filled(4096, 1));
      final folder = Directory('${dir.path}/设计稿')..createSync();
      final movie = File('${dir.path}/演示.mp4')
        ..writeAsBytesSync(List.filled(2048, 1));
      await pumpOver(
        tester,
        Center(
          child: SizedBox(
            width: 380,
            child: Material(
              color: Radix.white,
              borderRadius: BorderRadius.circular(WhisperRadius.l),
              child: ShellDropSendSheet(
                name: 'iMac',
                paths: [doc.path, folder.path, movie.path],
              ),
            ),
          ),
        ),
        const Size(480, 420),
      );
      await _render(tester, 'drop-sheet');
    });

    testWidgets('the fields', (tester) async {
      await pumpOver(
        tester,
        Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                PhoneSearchField(
                  controller: TextEditingController(text: '发版'),
                  hint: '搜索',
                  onChanged: (_) {},
                  onClear: () {},
                  clearLabel: '清除',
                  radius: WhisperRadius.capsule,
                ),
                const SizedBox(height: 16),
                ShellField(
                  label: '密码',
                  controller: TextEditingController(text: 'secret'),
                  obscure: true,
                  showLabel: '显示',
                  hideLabel: '隐藏',
                ),
              ],
            ),
          ),
        ),
        const Size(420, 260),
      );
      await _render(tester, 'fields-hidden');
      await tester.tap(find.byTooltip('显示'));
      await tester.pump(const Duration(seconds: 1));
      await _render(tester, 'fields-shown');
    });

    testWidgets('the palette', (tester) async {
      await pumpOver(
        tester,
        Material(
          type: MaterialType.transparency,
          child: ShellPalette(
            items: [
              PaletteItem(
                glyph: WhisperGlyph.info,
                name: 'iMac',
                category: '设备',
                onRun: () {},
              ),
              PaletteItem(
                glyph: WhisperGlyph.apps,
                name: '备忘录（iMac）',
                category: '应用',
                onRun: () {},
              ),
              PaletteItem(
                glyph: WhisperGlyph.speaker,
                name: '把这台的声音放到 iMac',
                category: '声音',
                onRun: () {},
              ),
              PaletteItem(
                glyph: WhisperGlyph.keyboard,
                name: '用这台的键鼠控制 iMac',
                category: '键鼠',
                onRun: () {},
              ),
              PaletteItem(
                glyph: WhisperGlyph.gear,
                name: '设置',
                category: '本机',
                onRun: () {},
              ),
            ],
            searchMessages: (_) async => const [],
          ),
        ),
        const Size(1144, 720),
      );
      expect(tester.takeException(), isNull);
      await _render(tester, 'palette');
    });

    testWidgets('the sheet of this device', (tester) async {
      await pumpOver(
        tester,
        Builder(
          builder: (context) => Center(
            child: Material(
              type: MaterialType.transparency,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.wc.raised,
                    borderRadius: BorderRadius.circular(WhisperRadius.l),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(20),
                    child: ShellGroup(
                      children: [
                        ShellRow(label: '地址', trailing: Text('192.168.31.8')),
                        ShellRow(label: '连接诊断', chevron: true),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const Size(600, 300),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('the floating paste island', () {
    for (final (name, stage, seconds, open) in [
      ('paste-island-open', RemoteClipboardPasteStage.receiving, 12, true),
      ('paste-island-small', RemoteClipboardPasteStage.receiving, 75, false),
      ('paste-island-ready', RemoteClipboardPasteStage.ready, null, true),
      ('paste-island-pasted', RemoteClipboardPasteStage.pasted, null, false),
    ]) {
      testWidgets(name, (tester) async {
        tester.view.physicalSize = const Size(460, 200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final source = IslandListSource();
        final center = IslandCenter(sources: [source]);
        await tester.pumpWidget(
          _app(
            RepaintBoundary(
              key: const ValueKey('shot'),
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFFB9D7FF), Color(0xFFF2C9EC)],
                  ),
                ),
                child: Stack(
                  children: [
                    ShellIsland(
                      center: center,
                      windowWidth: 460,
                      controlsLeft: 460,
                      titleRight: 0,
                      buttonsLeft: 920,
                      buttonsBottom: 0,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        IslandActivity activity(RemoteClipboardPasteStage stage) =>
            IslandActivity(
              id: 'paste',
              kind: IslandKind.copy,
              status: switch (stage) {
                RemoteClipboardPasteStage.pasted => IslandStatus.done,
                RemoteClipboardPasteStage.ready => IslandStatus.waiting,
                _ => IslandStatus.live,
              },
              since: DateTime(2026),
              urgent: true,
              presenter: PasteIslandPresenter(
                paste: RemoteClipboardPasteState(
                  id: 1,
                  peerId: 'p',
                  names: const ['设计稿-终版.zip'],
                  totalBytes: 624000000,
                  receivedBytes: stage == RemoteClipboardPasteStage.receiving
                      ? 182000000
                      : 624000000,
                  stage: stage,
                  secondsLeft: seconds,
                ),
                device: '小新',
                onCancel: () {},
              ),
            );
        source.put(activity(RemoteClipboardPasteStage.receiving));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(seconds: 1));
        if (stage != RemoteClipboardPasteStage.receiving) {
          source.put(activity(stage));
        }
        if (!open && stage == RemoteClipboardPasteStage.receiving) {
          await tester.pump(const Duration(seconds: 4));
        }
        if (!open) center.collapse();
        for (var frame = 0; frame < 80; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(tester.takeException(), isNull);
        await _render(tester, name);
        await tester.pump(const Duration(seconds: 12));
      });
    }
  });

  testWidgets('below 600 it is the phone list', (tester) async {
    await pumpShell(tester, const Size(390, 780));
    expect(tester.takeException(), isNull);
    expect(find.text('设备'), findsOneWidget);
    expect(find.byType(LiquidSegmented<int>), findsNothing);
    await _render(tester, 'shell-phone');
  });
}
