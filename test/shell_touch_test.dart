import 'dart:ui' show DisplayFeature, DisplayFeatureState, DisplayFeatureType;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/new_ui/shell/device_row_status.dart';
import 'package:whisper/new_ui/shell/shell_data.dart';
import 'package:whisper/new_ui/shell/shell_device_page.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/new_ui/shell/shell_phone.dart';
import 'package:whisper/new_ui/shell/shell_touch.dart';
import 'package:whisper/new_ui/shell/whisper_shell.dart';
import 'package:whisper/state/chat_session_list.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_device_art.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/widget/context_menu_region.dart';

DeviceData _device(String uid, String name, String platform, int id) =>
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

ChatSessionItem _session(DeviceData d, {bool connected = true}) =>
    ChatSessionItem(
      device: d,
      latestMessage: null,
      preview: '',
      lastTimestamp: 0,
      isConnected: connected,
      isNearby: true,
      hasHistory: true,
      avatarLabel: d.name.substring(0, 1),
    );

final _imac = _device('imac', 'iMac', 'macos', 0);
final _tp = _device('tp', 'ThinkPad X1 Carbon', 'windows', 1);
final _mi = _device('mi', 'Xiaomi 16', 'android', 2);

/// A shell with sample data, driven the way the device list screen drives it.
class _Harness extends StatefulWidget {
  const _Harness();

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  String? selected;
  int settingsClosed = 0;

  @override
  Widget build(BuildContext context) => WhisperShell(
    data: ShellData(
      self: _device('self', '这台手机', 'android', 9),
      sessions: [_session(_imac), _session(_tp), _session(_mi)],
      selectedPeerId: selected ?? 'imac',
      isPaired: (_) => true,
      factsFor: (s) => DeviceRowFacts(connected: s.isConnected, paired: true),
    ),
    actions: ShellActions(
      select: (uid) => setState(() => selected = uid),
      connect: _connected.add,
      disconnect: _disconnected.add,
      openPairing: ({bool startWithAddress = false}) async {
        await ShellContent.pushTop<void>(
          (context) => PhonePage(
            title: 'CONNECT',
            back: shellPageShowsBack(context),
            child: const SizedBox.expand(),
          ),
        );
      },
      removeDevice: (_) async {},
      contextActions: (_, {openCard}) => const <ContextMenuActionItem>[],
      openSound: () {},
      openInput: () {},
      openShareLinks: () {},
      openSettings: () async {
        await ShellContent.pushTop<void>(
          (context) => PhonePage(
            title: 'SETTINGS',
            back: shellPageShowsBack(context),
            child: Center(
              child: TextButton(
                onPressed: () => ShellContent.push<void>(
                  WhisperPageRoute<void>(
                    builder: (_) => const PhonePage(
                      title: 'LINKS',
                      child: SizedBox.expand(),
                    ),
                  ),
                ),
                child: const Text('OPEN LINKS'),
              ),
            ),
          ),
        );
        settingsClosed++;
      },
      openDiagnostics: (_) {},
      canControl: (d) => d.platform != 'android',
      openControl: _openControl,
      buildConversation: (_, d) => _Chat(key: ValueKey('chat-${d.uid}')),
      buildFiles: (_, d) => Text('FILES ${d.uid}'),
      buildApps: (_, d) => Text('APPS ${d.uid}'),
      buildPlace: (_, _, _, {titleKey, controlsKey}) => const SizedBox.shrink(),
      buildSelfPanel: (_) => const SizedBox.shrink(),
      buildCard: (_, _, _) => const SizedBox.shrink(),
      buildTouchCard:
          (
            context,
            d, {
            required bool page,
            required VoidCallback onClose,
            required ValueChanged<int> onOpenTab,
          }) => Material(
            color: context.wc.canvas,
            child: Column(
              mainAxisSize: page ? MainAxisSize.max : MainAxisSize.min,
              children: [
                const SizedBox(height: 100),
                Text(page ? 'DEVICE PAGE ${d.uid}' : 'CARD ${d.uid}'),
                TextButton(
                  onPressed: () => _openControl(d),
                  child: const Text('CONTROL ENTRY'),
                ),
                if (page) ...[
                  TextButton(
                    onPressed: () => onOpenTab(1),
                    child: const Text('ENTRY FILES'),
                  ),
                  TextButton(
                    onPressed: onClose,
                    child: const Text('CARD BACK'),
                  ),
                ],
              ],
            ),
          ),
      paletteItems: (_) => const [],
      searchMessages: (_, _) async => const [],
    ),
  );
}

/// Stands for the draft and scroll position of a real conversation.
class _Chat extends StatefulWidget {
  const _Chat({super.key});

  @override
  State<_Chat> createState() => _ChatState();
}

class _ChatState extends State<_Chat> {
  static int built = 0;
  final _draft = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    built++;
  }

  @override
  void dispose() {
    _draft.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Expanded(
        child: ListView.builder(
          key: const ValueKey('chat-list'),
          controller: _scroll,
          itemCount: 200,
          itemExtent: 40,
          itemBuilder: (_, i) => Text('line $i'),
        ),
      ),
      TextField(key: const ValueKey('draft'), controller: _draft),
    ],
  );
}

const _phoneSize = Size(474, 696);
const _openSize = Size(904, 640);
const _tabletLandscape = Size(1180, 820);

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

final _connected = <DeviceData>[];
final _disconnected = <DeviceData>[];

Future<void> _openControl(DeviceData d) => ShellContent.push<void>(
  WhisperPageRoute<void>(
    settings: const RouteSettings(name: ShellRoutes.control),
    builder: (_) => const PhonePage(title: 'CONTROL', child: SizedBox.expand()),
  ),
);

void main() {
  setUp(() {
    WhisperLayout.debugTouchOverride = true;
    _ChatState.built = 0;
  });
  tearDown(() => WhisperLayout.debugTouchOverride = null);

  Future<void> resize(
    WidgetTester tester,
    Size size, {
    List<DisplayFeature> features = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.displayFeatures = features;
    await settle(tester);
  }

  Future<void> pumpShell(
    WidgetTester tester,
    Size size, {
    List<DisplayFeature> features = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.displayFeatures = features;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const _Harness(),
      ),
    );
    await settle(tester);
  }

  Rect main_(WidgetTester tester) =>
      tester.getRect(find.byType(ShellDevicePage));

  bool showsList(WidgetTester tester) {
    final title = find.text('设备');
    if (title.evaluate().isEmpty) return false;
    final x = tester.getTopLeft(title).dx;
    return x >= 0;
  }

  Future<void> tapRow(WidgetTester tester, String name) async {
    await tester.tap(find.text(name).first);
    await settle(tester);
  }

  /// Back, the way a page's arrow or Android's button asks for it.
  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await settle(tester);
  }

  Finder topButton(WhisperGlyph g) =>
      find.byWidgetPredicate((w) => w is WhisperIcon && w.glyph == g);

  Finder glyph(WhisperGlyph g) => find.byWidgetPredicate(
    (w) =>
        (w is PhoneBarButton && w.glyph == g) ||
        (w is ShellIconButton && w.glyph == g) ||
        (w is ShellToolCapsuleItem && w.glyph == g),
  );

  group('the same shell at every width', () {
    for (final (name, size, sidebarExpected) in const [
      ('iPad portrait', Size(820, 1180), true),
      ('iPad landscape', Size(1180, 820), true),
      ('iPad split', Size(405, 820), false),
      ('foldable closed', Size(474, 696), false),
      ('foldable open', Size(904, 640), true),
      ('wide foldable open', Size(1006, 711), true),
      ('small wide portrait', Size(533, 857), false),
      ('small wide landscape', Size(857, 533), true),
      ('tri-fold one', Size(422, 937), false),
      ('tri-fold two', Size(860, 937), true),
      ('tri-fold three', Size(1337, 937), true),
      ('narrowest', Size(320, 568), false),
      ('half an open fold', Size(640, 904), true),
    ]) {
      testWidgets('$name fits', (tester) async {
        await pumpShell(tester, size);
        expect(tester.takeException(), isNull);
        final list = tester.widget<ShellPhoneList>(find.byType(ShellPhoneList));
        expect(list.sidebar, sidebarExpected);
        if (sidebarExpected) {
          final width = tester.getSize(find.byType(ShellPhoneList)).width;
          expect(width, inInclusiveRange(240, 300));
          // There is a device on screen without tapping one.
          expect(find.byType(ShellDevicePage), findsOneWidget);
          expect(
            tester.getRect(find.byType(ShellDevicePage)).width,
            greaterThanOrEqualTo(360),
          );
          // The tabs and the title do not meet.
          final title = tester.getRect(
            find.descendant(
              of: find.byType(ShellDevicePage),
              matching: find.text('iMac'),
            ),
          );
          final tabs = tester.getRect(find.byType(LiquidSegmented<int>));
          expect(title.right, lessThanOrEqualTo(tabs.left));
        } else {
          // Nothing is built behind a phone's list.
          expect(find.byType(ShellDevicePage), findsNothing);
        }
      });
    }
  });

  group('beside a sidebar', () {
    testWidgets('a toolbar tall enough to touch, control is on the card', (
      tester,
    ) async {
      await pumpShell(tester, _tabletLandscape);
      expect(glyph(WhisperGlyph.keyboard), findsNothing);
      expect(glyph(WhisperGlyph.info), findsOneWidget);
      expect(find.text('对话'), findsOneWidget);
      // Tabs: 36 to look at, 48 to hit.
      expect(tester.getSize(find.byType(LiquidSegmented<int>)).height, 48);
      expect(
        tester.getSize(find.byKey(const ValueKey('liquid-thumb'))).height,
        lessThanOrEqualTo(33),
      );
    });

    testWidgets('a phone has no control button', (tester) async {
      await pumpShell(tester, _tabletLandscape);
      await tapRow(tester, 'Xiaomi 16');
      expect(glyph(WhisperGlyph.keyboard), findsNothing);
    });

    testWidgets('the top of the sidebar is a phone\'s, with no bottom corner', (
      tester,
    ) async {
      await pumpShell(tester, _tabletLandscape);
      expect(find.text('设备'), findsOneWidget);
      expect(glyph(WhisperGlyph.search), findsNothing);
      expect(glyph(WhisperGlyph.speaker), findsNothing);
      expect(glyph(WhisperGlyph.link), findsNothing);
    });

    for (final size in const [_tabletLandscape, _openSize]) {
      testWidgets('at $size the card floats over the content', (tester) async {
        await pumpShell(tester, size);
        final before = main_(tester).width;
        await tester.tap(glyph(WhisperGlyph.info));
        await settle(tester);
        expect(find.text('CARD imac'), findsOneWidget);
        expect(main_(tester).width, before);
      });
    }

    testWidgets('a tap anywhere else closes the card and still does its job', (
      tester,
    ) async {
      await pumpShell(tester, _tabletLandscape);
      await tester.tap(glyph(WhisperGlyph.info));
      await settle(tester);
      expect(find.text('CARD imac'), findsOneWidget);
      // The left of the draft field: what the card does not cover.
      await tester.tapAt(
        tester.getRect(find.byKey(const ValueKey('draft'))).centerLeft +
            const Offset(20, 0),
      );
      await settle(tester);
      expect(find.text('CARD imac'), findsNothing);
      expect(tester.testTextInput.isVisible, isTrue);
    });

    testWidgets('a finger pulls the card away to the right', (tester) async {
      await pumpShell(tester, _tabletLandscape);
      await tester.tap(glyph(WhisperGlyph.info));
      await settle(tester);
      final start = tester.getTopLeft(find.text('CARD imac'));

      // Not far enough, and slowly: it comes back.
      await tester.timedDrag(
        find.text('CARD imac'),
        const Offset(40, 0),
        const Duration(seconds: 1),
      );
      await settle(tester);
      expect(find.text('CARD imac'), findsOneWidget);
      expect(tester.getTopLeft(find.text('CARD imac')), start);

      await tester.timedDrag(
        find.text('CARD imac'),
        const Offset(150, 0),
        const Duration(seconds: 1),
      );
      await settle(tester);
      expect(find.text('CARD imac'), findsNothing);

      // It opens again where it belongs.
      await tester.tap(glyph(WhisperGlyph.info));
      await settle(tester);
      expect(tester.getTopLeft(find.text('CARD imac')), start);
    });

    testWidgets('choosing another device closes the card, for good', (
      tester,
    ) async {
      await pumpShell(tester, _tabletLandscape);
      await tester.tap(glyph(WhisperGlyph.info));
      await settle(tester);
      await tapRow(tester, 'ThinkPad X1 Carbon');
      expect(find.text('CARD imac'), findsNothing);
      expect(find.text('CARD tp'), findsNothing);
      await tapRow(tester, 'iMac');
      expect(find.text('CARD imac'), findsNothing);
    });

    testWidgets('settings open in the content and a device leaves them', (
      tester,
    ) async {
      await pumpShell(tester, _tabletLandscape);
      await tester.tap(glyph(WhisperGlyph.info));
      await settle(tester);
      await tester.tap(topButton(WhisperGlyph.gear));
      await settle(tester);
      expect(find.text('SETTINGS'), findsOneWidget);
      // The sidebar stays, and nothing in it is selected.
      expect(find.byType(ShellPhoneList), findsOneWidget);
      expect(
        tester
            .widget<ShellPhoneList>(find.byType(ShellPhoneList))
            .selectedPeerId,
        isNull,
      );
      // A top page has no arrow beside a sidebar.
      expect(glyph(WhisperGlyph.back), findsNothing);
      // Tapping the gear closed the card.
      expect(find.text('CARD imac'), findsNothing);

      // Further in has one, and comes back here.
      await tester.tap(find.text('OPEN LINKS'));
      await settle(tester);
      expect(find.text('LINKS'), findsOneWidget);
      expect(glyph(WhisperGlyph.back).hitTestable(), findsOneWidget);
      await back(tester);
      expect(find.text('SETTINGS').hitTestable(), findsOneWidget);

      await tapRow(tester, 'iMac');
      expect(find.text('SETTINGS'), findsNothing);
      expect(
        tester
            .widget<ShellPhoneList>(find.byType(ShellPhoneList))
            .selectedPeerId,
        'imac',
      );
    });

    testWidgets('connect replaces settings rather than piling on them', (
      tester,
    ) async {
      await pumpShell(tester, _tabletLandscape);
      await tester.tap(topButton(WhisperGlyph.gear));
      await settle(tester);
      await tester.tap(topButton(WhisperGlyph.plus));
      await settle(tester);
      expect(find.text('CONNECT'), findsOneWidget);
      expect(find.text('SETTINGS'), findsNothing);
      final state = tester.state<_HarnessState>(find.byType(_Harness));
      expect(state.settingsClosed, 1);
    });
  });

  group('the keyboard', () {
    testWidgets('moves the page once, and what is inside does not count it', (
      tester,
    ) async {
      await pumpShell(tester, _phoneSize);
      await tapRow(tester, 'iMac');
      final before = tester.getSize(find.byKey(const ValueKey('chat-imac')));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await settle(tester);
      final chat = find.byKey(const ValueKey('chat-imac'));
      expect(tester.getSize(chat).height, before.height - 300);
      // A Scaffold in the page would otherwise take it off a second time.
      expect(MediaQuery.viewInsetsOf(tester.element(chat)).bottom, 0);
    });
  });

  group('connecting and letting go are in the toolbar', () {
    setUp(() {
      _connected.clear();
      _disconnected.clear();
    });

    for (final size in [_tabletLandscape, _phoneSize]) {
      testWidgets('a connected device can be disconnected at $size', (
        tester,
      ) async {
        await pumpShell(tester, size);
        if (size == _phoneSize) await tapRow(tester, 'iMac');
        final button = find.byKey(const ValueKey('device-connection'));
        expect(button, findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (w) => w is WhisperIcon && w.glyph == WhisperGlyph.power,
          ),
          findsOneWidget,
        );
        await tester.tap(button);
        await tester.pump();
        expect(_disconnected.map((d) => d.name), ['iMac']);
      });
    }
  });

  group('the phone\'s stack', () {
    testWidgets('a row opens the device over the list, and back returns', (
      tester,
    ) async {
      await pumpShell(tester, _phoneSize);
      expect(showsList(tester), isTrue);
      await tapRow(tester, 'iMac');
      expect(find.byType(ShellDevicePage), findsOneWidget);
      expect(main_(tester).left, 0);
      // No tabs: the title and ⋯ open the device page.
      expect(find.byType(LiquidSegmented<int>), findsNothing);
      expect(glyph(WhisperGlyph.more), findsOneWidget);
      // Taking over a computer is not an everyday thing: it is on the device page.
      expect(glyph(WhisperGlyph.keyboard), findsNothing);
      await tester.tap(glyph(WhisperGlyph.back));
      await settle(tester);
      // It goes, as a page popped off a stack does.
      expect(find.byType(ShellDevicePage), findsNothing);
      expect(showsList(tester), isTrue);
    });

    testWidgets('chat → device page → files → back → back → back', (
      tester,
    ) async {
      await pumpShell(tester, _phoneSize);
      await tapRow(tester, 'iMac');
      await tester.tap(glyph(WhisperGlyph.more));
      await settle(tester);
      expect(find.text('DEVICE PAGE imac'), findsOneWidget);

      await tester.tap(find.text('ENTRY FILES'));
      await settle(tester);
      expect(find.text('FILES imac').hitTestable(), findsOneWidget);

      await back(tester);
      expect(find.text('DEVICE PAGE imac'), findsOneWidget);
      await back(tester);
      expect(find.text('DEVICE PAGE imac'), findsNothing);
      expect(find.byKey(const ValueKey('draft')).hitTestable(), findsOneWidget);
      await back(tester);
      expect(find.byType(ShellDevicePage), findsNothing);
    });

    testWidgets('settings from the list go back to the list', (tester) async {
      await pumpShell(tester, _phoneSize);
      await tester.tap(topButton(WhisperGlyph.gear));
      await settle(tester);
      expect(find.text('SETTINGS'), findsOneWidget);
      expect(glyph(WhisperGlyph.back), findsOneWidget);
      await tester.tap(glyph(WhisperGlyph.back));
      await settle(tester);
      expect(find.text('SETTINGS'), findsNothing);
      expect(find.byType(ShellDevicePage), findsNothing);
      expect(showsList(tester), isTrue);
      final state = tester.state<_HarnessState>(find.byType(_Harness));
      expect(state.settingsClosed, 1);
    });

    testWidgets('the system back button walks the same way', (tester) async {
      await pumpShell(tester, _phoneSize);
      await tapRow(tester, 'iMac');
      await back(tester);
      expect(find.byType(ShellDevicePage), findsNothing);
      // Nothing left: not for the app. The system leaves it.
      expect(await tester.binding.handlePopRoute(), isFalse);
    });
  });

  group('a fold loses nothing', () {
    Future<void> type(WidgetTester tester, String text) async {
      await tester.enterText(find.byKey(const ValueKey('draft')), text);
      await tester.pump();
    }

    String draft(WidgetTester tester) => tester
        .widget<TextField>(find.byKey(const ValueKey('draft')))
        .controller!
        .text;

    testWidgets('the device, its draft and its scroll', (tester) async {
      await pumpShell(tester, _openSize);
      await tapRow(tester, 'ThinkPad X1 Carbon');
      final built = _ChatState.built;
      await type(tester, '还没写完');
      await tester.drag(
        find.byKey(const ValueKey('chat-list')),
        const Offset(0, -800),
      );
      await settle(tester);
      final scroll = tester
          .widget<ListView>(find.byKey(const ValueKey('chat-list')))
          .controller!
          .offset;
      expect(scroll, greaterThan(0));

      await resize(tester, _phoneSize);
      expect(tester.takeException(), isNull);
      expect(find.byType(ShellDevicePage), findsOneWidget);
      expect(main_(tester).left, 0);
      expect(find.text('ThinkPad X1 Carbon').hitTestable(), findsOneWidget);
      expect(draft(tester), '还没写完');
      expect(_ChatState.built, built, reason: 'the page was not rebuilt');
      expect(
        tester
            .widget<ListView>(find.byKey(const ValueKey('chat-list')))
            .controller!
            .offset,
        scroll,
      );

      await resize(tester, _openSize);
      expect(draft(tester), '还没写完');
      expect(_ChatState.built, built);
      expect(
        tester
            .widget<ShellPhoneList>(find.byType(ShellPhoneList))
            .selectedPeerId,
        'tp',
      );
    });

    testWidgets('the tab', (tester) async {
      await pumpShell(tester, _openSize);
      await tester.tap(find.text('文件'));
      await settle(tester);
      expect(find.text('FILES imac').hitTestable(), findsOneWidget);

      await resize(tester, _phoneSize);
      expect(find.text('FILES imac').hitTestable(), findsOneWidget);
      // Back from a tab nobody pushed is the list.
      await resize(tester, _openSize);
      expect(find.text('FILES imac').hitTestable(), findsOneWidget);
      expect(
        tester
            .widget<LiquidSegmented<int>>(find.byType(LiquidSegmented<int>))
            .selected,
        1,
      );
      await resize(tester, _phoneSize);
      await back(tester);
      expect(find.byType(ShellDevicePage), findsNothing);
    });

    testWidgets('the card becomes the device page and back', (tester) async {
      await pumpShell(tester, _openSize);
      await tester.tap(glyph(WhisperGlyph.info));
      await settle(tester);
      expect(find.text('CARD imac'), findsOneWidget);

      await resize(tester, _phoneSize);
      expect(find.text('DEVICE PAGE imac'), findsOneWidget);
      await resize(tester, _openSize);
      expect(find.text('CARD imac'), findsOneWidget);
      expect(find.text('DEVICE PAGE imac'), findsNothing);
    });

    testWidgets('a list on screen opens to a device', (tester) async {
      await pumpShell(tester, _phoneSize);
      expect(find.byType(ShellDevicePage), findsNothing);
      await resize(tester, _openSize);
      expect(find.byType(ShellDevicePage), findsOneWidget);
    });

    testWidgets('settings stay open through a fold', (tester) async {
      await pumpShell(tester, _openSize);
      await tester.tap(topButton(WhisperGlyph.gear));
      await settle(tester);
      expect(glyph(WhisperGlyph.back), findsNothing);
      await resize(tester, _phoneSize);
      expect(find.text('SETTINGS').hitTestable(), findsOneWidget);
      expect(glyph(WhisperGlyph.back).hitTestable(), findsOneWidget);
      await resize(tester, _openSize);
      expect(find.text('SETTINGS').hitTestable(), findsOneWidget);
      expect(glyph(WhisperGlyph.back), findsNothing);
    });

    testWidgets('an open sheet stays open and changes shape', (tester) async {
      await pumpShell(tester, _openSize);
      final context = tester.element(find.byType(ShellPhoneList));
      showPhoneSheet<void>(context, builder: (_) => const Text('A SHEET'));
      await settle(tester);
      final centred = tester.getCenter(find.text('A SHEET'));
      expect(centred.dx, closeTo(_openSize.width / 2, 1));
      expect(centred.dy, lessThan(_openSize.height * .7));

      await resize(tester, _phoneSize);
      expect(find.text('A SHEET'), findsOneWidget);
      expect(
        tester.getCenter(find.text('A SHEET')).dy,
        greaterThan(_phoneSize.height * .7),
      );
    });
  });

  group('postures', () {
    DisplayFeature fold(Rect bounds) => DisplayFeature(
      bounds: bounds,
      type: DisplayFeatureType.fold,
      state: DisplayFeatureState.postureHalfOpened,
    );

    testWidgets('book: the sidebar ends on the fold', (tester) async {
      await pumpShell(
        tester,
        _openSize,
        features: [fold(const Rect.fromLTWH(452, 0, 0, 640))],
      );
      expect(tester.getSize(find.byType(ShellPhoneList)).width, 452);
      expect(main_(tester).left, closeTo(452, 1));
    });

    testWidgets('tabletop: only the control page gives up the sidebar', (
      tester,
    ) async {
      const size = Size(640, 904);
      await pumpShell(
        tester,
        size,
        features: [fold(const Rect.fromLTWH(0, 452, 640, 0))],
      );
      expect(tester.getSize(find.byType(ShellPhoneList)).width, 240);
      await tester.tap(glyph(WhisperGlyph.info));
      await settle(tester);
      await tester.tap(find.text('CONTROL ENTRY'));
      await settle(tester);
      expect(find.text('CONTROL'), findsOneWidget);
      expect(find.byType(ShellPhoneList).hitTestable(), findsNothing);
      expect(tester.getSize(find.text('CONTROL')).height, greaterThan(0));
      await back(tester);
      expect(tester.getSize(find.byType(ShellPhoneList)).width, 240);
    });
  });

  group('what a peer looks like', () {
    test('a tablet is its own picture and is not controlled', () {
      expect(deviceKindFor('android', tablet: true), DeviceKind.tablet);
      expect(deviceKindFor('android'), DeviceKind.phone);
      expect(deviceKindFor('ipad'), DeviceKind.tablet);
      expect(DeviceKind.tablet.handheld, isTrue);
      expect(DeviceKind.laptop.handheld, isFalse);
    });
  });

  testWidgets('the system bar is respected on touch', (tester) async {
    await pumpShell(tester, _tabletLandscape);
    tester.view.padding = const FakeViewPadding(top: 28);
    addTearDown(tester.view.resetPadding);
    await tester.pump();
    final title = tester.getTopLeft(find.text('设备'));
    expect(title.dy, greaterThanOrEqualTo(28));
    expect(SystemChannels.platform, isNotNull);
  });
}
