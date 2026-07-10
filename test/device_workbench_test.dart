import 'dart:ui' show SemanticsFlag;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/state/chat_session_list.dart';
import 'package:whisper/state/connection_coordinator.dart';
import 'package:whisper/state/peer_endpoint.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/app_interactive_tile.dart';
import 'package:whisper/widget/context_menu_region.dart';
import 'package:whisper/widget/device_workbench.dart';

void main() {
  testWidgets('shows local discovery, all groups, and an unpaired candidate',
      (tester) async {
    final selected = <String>[];
    await _pumpWorkbench(
      tester,
      width: 700,
      sessions: _sessions(),
      candidates: <NearbyCandidatePresentation>[
        NearbyCandidatePresentation(
          publicKeyHash:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          serviceName: 'whisper-aaaaaaaa',
          endpoint: PeerEndpoint(host: '192.168.1.40', port: 10002),
          displayName: 'New Mac',
          platform: 'macos',
          lastSeenAt: DateTime.utc(2026, 7, 10),
        ),
      ],
      onSelectSession: (item) => selected.add(item.device.uid),
      onSelectCandidate: (candidate) => selected.add(candidate.id),
    );

    expect(find.text('Studio Mac'), findsOneWidget);
    expect(
      find.widgetWithText(SelectableText, 'Local address: 192.168.1.5:10002'),
      findsOneWidget,
    );
    expect(find.text('Broadcasting and discovering'), findsOneWidget);
    expect(find.text('Connected devices'), findsOneWidget);
    expect(find.text('Available nearby'), findsWidgets);
    expect(find.text('Recent devices'), findsOneWidget);
    expect(find.text('New Mac'), findsOneWidget);
    expect(find.textContaining('Unpaired nearby device'), findsOneWidget);
    expect(find.byType(AppInteractiveTile), findsNWidgets(4));

    await tester.tap(find.text('Connected Mac'));
    await tester.tap(find.text('New Mac'));
    expect(selected.first, 'connected');
    expect(selected.last, startsWith('aaaaaaaa'));
  });

  testWidgets('empty and no-result states expose recovery actions',
      (tester) async {
    var manualConnects = 0;
    await _pumpWorkbench(
      tester,
      width: 420,
      sessions: const <ChatSessionItem>[],
      onManualConnect: () => manualConnects += 1,
    );

    expect(find.text('No devices yet'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Connect manually'));
    expect(manualConnects, 1);

    await _pumpWorkbench(
      tester,
      width: 420,
      sessions: _sessions(),
    );
    await tester.enterText(
      find.byKey(DeviceWorkbenchPane.searchFieldKey),
      'does-not-exist',
    );
    await tester.pump();

    expect(find.text('No results'), findsOneWidget);
    expect(find.text('Clear search'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Clear search'));
    await tester.pump();
    expect(find.text('Connected Mac'), findsOneWidget);
  });

  testWidgets('search supports Command or Control F and Escape',
      (tester) async {
    await _pumpWorkbench(
      tester,
      width: 420,
      sessions: _sessions(),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(
      tester
          .widget<TextField>(
            find.byKey(DeviceWorkbenchPane.searchFieldKey),
          )
          .focusNode!
          .hasFocus,
      isTrue,
    );

    await tester.enterText(
      find.byKey(DeviceWorkbenchPane.searchFieldKey),
      'phone',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(DeviceWorkbenchPane.searchFieldKey))
          .controller!
          .text,
      isEmpty,
    );
  });

  testWidgets(
      'wide actions show labels while narrow disabled actions explain why',
      (tester) async {
    const disabledReason = 'No connected speaker';
    final actions = <DeviceWorkbenchAction>[
      const DeviceWorkbenchAction(
        kind: DeviceWorkbenchActionKind.manualConnect,
        onPressed: _noop,
      ),
      const DeviceWorkbenchAction(
        kind: DeviceWorkbenchActionKind.audioShare,
        disabledReason: disabledReason,
      ),
      const DeviceWorkbenchAction(
        kind: DeviceWorkbenchActionKind.remoteInput,
        onPressed: _noop,
      ),
      const DeviceWorkbenchAction(
        kind: DeviceWorkbenchActionKind.settings,
        onPressed: _noop,
      ),
    ];

    await _pumpWorkbench(
      tester,
      width: 700,
      sessions: _sessions(),
      actions: actions,
    );
    expect(find.text('Connect manually'), findsOneWidget);
    expect(find.text('Share system audio'), findsOneWidget);
    expect(find.text('Keyboard and mouse workspace'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    for (final label in <String>[
      'Connect manually',
      'Share system audio',
      'Keyboard and mouse workspace',
      'Settings',
    ]) {
      expect(
        tester.getSize(find.widgetWithText(FilledButton, label)).height,
        greaterThanOrEqualTo(WhisperUi.minInteractiveSize),
        reason: label,
      );
    }

    final semantics = tester.ensureSemantics();
    await _pumpWorkbench(
      tester,
      width: 340,
      sessions: _sessions(),
      actions: actions,
    );
    expect(find.byTooltip('Connect manually'), findsOneWidget);
    expect(
      find.byTooltip('Unavailable: $disabledReason'),
      findsOneWidget,
    );
    final audioSemantics = tester.getSemantics(
      find.byKey(const ValueKey<String>('workbench-action-audioShare')),
    );
    expect(audioSemantics.label, contains(disabledReason));
    expect(audioSemantics.hasFlag(SemanticsFlag.isEnabled), isFalse);
    semantics.dispose();
  });

  testWidgets('session rows keep injected long-press connection actions',
      (tester) async {
    var disconnects = 0;
    await _pumpWorkbench(
      tester,
      width: 420,
      sessions: _sessions(),
      sessionContextActions: (session) => <ContextMenuActionItem>[
        ContextMenuActionItem(
          label: 'Disconnect',
          onSelected: () => disconnects += 1,
        ),
      ],
    );

    await tester.longPress(find.text('Connected Mac'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(disconnects, 1);
  });

  testWidgets('session trailing menu is 44px and keyboard operable',
      (tester) async {
    final semantics = tester.ensureSemantics();
    var disconnects = 0;
    await _pumpWorkbench(
      tester,
      width: 420,
      sessions: _sessions(),
      actions: const <DeviceWorkbenchAction>[],
      sessionContextActions: (session) => <ContextMenuActionItem>[
        ContextMenuActionItem(
          label: 'Disconnect',
          onSelected: () => disconnects += 1,
        ),
      ],
    );

    final menu = find.byKey(
      const ValueKey<String>('device-session-menu-connected'),
    );
    expect(menu, findsOneWidget);
    expect(
      tester.getSize(menu).shortestSide,
      greaterThanOrEqualTo(WhisperUi.minInteractiveSize),
    );
    expect(tester.getSemantics(menu).label, contains('Connected Mac'));

    var focused = false;
    for (var index = 0; index < 8 && !focused; index += 1) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      focused = tester.getSemantics(menu).hasFlag(SemanticsFlag.isFocused);
    }
    expect(focused, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Disconnect'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(disconnects, 1);
    semantics.dispose();
  });

  testWidgets('two-times text scale keeps compact workbench overflow free',
      (tester) async {
    await _pumpWorkbench(
      tester,
      width: 340,
      height: 760,
      textScale: 2,
      sessions: _sessions(),
    );

    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byKey(DeviceWorkbenchPane.searchFieldKey)).height,
      greaterThanOrEqualTo(WhisperUi.minInteractiveSize),
    );
  });

  testWidgets('discovery failures stay retryable without narrow overflow',
      (tester) async {
    var retries = 0;
    await _pumpWorkbench(
      tester,
      width: 340,
      height: 760,
      textScale: 2,
      sessions: _sessions(),
      discovery: const LocalDiscoveryPresentation(
        phase: LocalDiscoveryPhase.unavailable,
        canRetry: true,
        errorMessage: 'Network interface unavailable',
      ),
      onRetryDiscovery: () => retries += 1,
    );

    expect(
      find.text('Local discovery failed: Network interface unavailable'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Retry discovery'));
    expect(retries, 1);
  });
}

Future<void> _pumpWorkbench(
  WidgetTester tester, {
  required double width,
  double height = 900,
  double textScale = 1,
  required List<ChatSessionItem> sessions,
  List<NearbyCandidatePresentation> candidates =
      const <NearbyCandidatePresentation>[],
  List<DeviceWorkbenchAction>? actions,
  ValueChanged<ChatSessionItem>? onSelectSession,
  ValueChanged<NearbyCandidatePresentation>? onSelectCandidate,
  VoidCallback? onManualConnect,
  List<ContextMenuActionItem> Function(ChatSessionItem)? sessionContextActions,
  LocalDiscoveryPresentation discovery = const LocalDiscoveryPresentation(
    phase: LocalDiscoveryPhase.active,
    canRetry: false,
  ),
  VoidCallback? onRetryDiscovery,
}) async {
  await tester.binding.setSurfaceSize(Size(width, height));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.lightTheme,
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: DeviceWorkbenchPane(
          localDeviceName: 'Studio Mac',
          localPlatform: 'macos',
          localAddress: '192.168.1.5:10002',
          discovery: discovery,
          sessions: sessions,
          candidates: candidates,
          selectedPeerId: 'connected',
          actions: actions ??
              <DeviceWorkbenchAction>[
                DeviceWorkbenchAction(
                  kind: DeviceWorkbenchActionKind.manualConnect,
                  onPressed: onManualConnect ?? _noop,
                ),
                const DeviceWorkbenchAction(
                  kind: DeviceWorkbenchActionKind.settings,
                  onPressed: _noop,
                ),
              ],
          onSelectSession: onSelectSession ?? (_) {},
          onSelectCandidate: onSelectCandidate ?? (_) {},
          onRetryDiscovery: onRetryDiscovery ?? _noop,
          sessionContextActions: sessionContextActions,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

List<ChatSessionItem> _sessions() {
  const strings = ChatSessionPreviewStrings(
    connectedNow: 'Connected now',
    nearbyAvailable: 'Available nearby',
    noMessagesYet: 'No messages yet',
    sharedFile: 'Shared a file',
  );
  return ChatSessionListBuilder.build(
    devices: <DeviceData>[
      _device(
        'recent',
        name: 'Old Laptop',
        host: '192.168.1.30',
        lastTime: 10,
      ),
      _device(
        'nearby',
        name: 'Nearby Phone',
        host: '192.168.1.20',
        around: true,
        lastTime: 20,
      ),
      _device(
        'connected',
        name: 'Connected Mac',
        host: '192.168.1.10',
        around: true,
        lastTime: 30,
      ),
    ],
    latestMessages: const {},
    connectedPeerIds: const <String>{'connected'},
    strings: strings,
  );
}

DeviceData _device(
  String uid, {
  required String name,
  required String host,
  bool around = false,
  int lastTime = 0,
}) {
  return DeviceData(
    id: 0,
    uid: uid,
    name: name,
    host: host,
    port: 10002,
    password: '',
    platform: uid == 'nearby' ? 'android' : 'macos',
    isServer: false,
    online: false,
    clipboard: false,
    auth: false,
    lastTime: lastTime,
    around: around,
  );
}

void _noop() {}
