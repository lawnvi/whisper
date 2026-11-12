// The redesigned shell with sample data, in a real window, for looking at what
// the system draws: mica, the window buttons, the corners, the top edge. It does
// not start the app's services or touch its data or keys, so it is safe to run
// beside an installed Whisper and from a remote session's scheduled task.
//
//   flutter run -d windows -t tool/preview/new_ui_shell.dart
//
// WHISPER_PREVIEW_DARK=1 for the dark theme.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:whisper/helper/device_form_factor.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/phone/phone_connect_page.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/new_ui/shell/device_row_status.dart';
import 'package:whisper/new_ui/shell/shell_data.dart';
import 'package:whisper/new_ui/shell/shell_device_card.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/new_ui/shell/shell_phone_device.dart';
import 'package:whisper/new_ui/shell/shell_touch.dart';
import 'package:whisper/new_ui/shell/shell_window_chrome.dart';
import 'package:whisper/new_ui/shell/whisper_shell.dart';
import 'package:whisper/remote_input/mobile_control_screen.dart';
import 'package:whisper/state/chat_session_list.dart';
import 'package:whisper/state/pairing_invite.dart';
import 'package:whisper/state/peer_profile.dart' show DeviceFormFactor;
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';
import 'package:whisper/theme/whisper_window.dart';
import 'package:whisper/widget/context_menu_region.dart';
import 'package:window_manager/window_manager.dart';

final _dark = Platform.environment['WHISPER_PREVIEW_DARK'] == '1';
const _sampleKeyHash = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

DeviceData _device(int id, String uid, String name, String platform) =>
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
);

final _sessions = [
  _session(_device(0, 'imac', 'iMac', 'macos'), connected: true),
  _session(
    _device(1, 'tp', 'ThinkPad X1 Carbon', 'windows'),
    connected: true,
    preview: 'http://192.168.31.8:10003/k7qm',
  ),
  _session(
    _device(2, 'mi', 'Xiaomi 16', 'android'),
    connected: true,
    preview: '收到',
  ),
  _session(_device(3, 'pad', 'Redmi Pad', 'android'), nearby: true),
  _session(_device(4, 'ub', 'Ubuntu', 'linux')),
];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // A touch screen: on an emulator or a simulator, to look at the tablet and
  // foldable layouts. It has no window to dress.
  if (WhisperLayout.touchPlatform) {
    unawaited(DeviceFormFactors.shared.record('pad', DeviceFormFactor.tablet));
    runApp(const _Preview());
    return;
  }
  await windowManager.ensureInitialized();
  unawaited(
    windowManager.waitUntilReadyToShow(
      WhisperWindow.options(const Size(1144, 720)),
      () async {
        await WhisperWindow.enableMaterial(
          _dark ? Brightness.dark : Brightness.light,
        );
        await windowManager.show();
        await windowManager.focus();
      },
    ),
  );
  runApp(const _Preview());
}

class _Preview extends StatefulWidget {
  const _Preview();

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  String _selected = 'imac';

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.lightTheme,
    darkTheme: AppTheme.darkTheme,
    themeMode: _dark ? ThemeMode.dark : ThemeMode.light,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    builder: (context, child) => WhisperLayout.touchPlatform
        ? child ?? const SizedBox.shrink()
        : ShellWindowChrome(child: child ?? const SizedBox.shrink()),
    home: WhisperShell(
      data: ShellData(
        self: _device(9, 'self', 'xiaoxin 的笔记本', 'windows'),
        sessions: _sessions,
        selectedPeerId: _selected,
        isPaired: (d) => d.uid != 'pad',
        factsFor: (s) => DeviceRowFacts(
          connected: s.isConnected,
          nearby: s.isNearby,
          paired: s.device.uid != 'pad',
          preview: s.preview,
          offlineSince: '昨天 22:14',
          transferName: s.device.uid == 'imac' ? 'log.txt' : null,
          transferPercent: s.device.uid == 'imac' ? 59 : null,
        ),
      ),
      actions: ShellActions(
        select: (uid) => setState(() => _selected = uid ?? _selected),
        connect: (_) {},
        disconnect: (_) {},
        openPairing: ({bool startWithAddress = false}) async {
          if (!ShellContent.attached) return;
          await ShellContent.pushTop<void>(
            (_) => PhoneConnectPage(
              localInvite: PairingInvite(
                host: '192.168.31.8',
                port: 10002,
                peerId: '00000000-0000-4000-8000-000000000000',
                publicKeyHash: _sampleKeyHash,
              ),
              localName: '这台手机',
              fingerprint: '7F3A19C204DE',
              scanner:
                  (
                    _, {
                    required onReady,
                    required onCode,
                    required onPermission,
                  }) => const SizedBox.shrink(),
            ),
          );
        },
        removeDevice: (_) async {},
        sendDropped: (_, _) {},
        contextActions: (_, {openCard}) => const <ContextMenuActionItem>[],
        openSound: () {},
        openInput: () {},
        openShareLinks: () {},
        openSettings: () {
          if (!ShellContent.attached) return;
          unawaited(
            ShellContent.pushTop<void>(
              (context) => PhonePage(
                title: '设置',
                back: shellPageShowsBack(context),
                child: const Center(child: Text('设置')),
              ),
            ),
          );
        },
        openDiagnostics: (_) {},
        canControl: (d) => d.platform != 'android' && d.uid != 'ub',
        openControl: (d) => unawaited(
          ShellContent.push<void>(
            WhisperPageRoute<void>(
              settings: const RouteSettings(name: ShellRoutes.control),
              builder: (_) => MobileControlScreen(
                peerId: d.uid,
                peerName: d.name,
                deviceArt: deviceArtFor(d, size: 104),
                onStart: (_) async {},
                onStop: () async {},
              ),
            ),
          ),
        ),
        buildTouchCard:
            (
              context,
              d, {
              required bool page,
              required VoidCallback onClose,
              required ValueChanged<int> onOpenTab,
            }) {
              return page
                  ? ShellPhoneDevicePage(
                      device: d,
                      connected: true,
                      onBack: onClose,
                      entries: [
                        ShellDeviceEntry(
                          glyph: WhisperGlyph.folder,
                          title: '文件',
                          onTap: () => onOpenTab(1),
                        ),
                        ShellDeviceEntry(
                          glyph: WhisperGlyph.apps,
                          title: '应用',
                          onTap: () => onOpenTab(2),
                        ),
                      ],
                      onSearchHistory: () {},
                      onDiagnostics: () {},
                      onRemove: (_) async {},
                    )
                  : ShellDeviceCard(
                      device: d,
                      connected: true,
                      paired: true,
                      touch: true,
                      onClose: onClose,
                      statusLine: '已连接',
                      deviceLoader: (_) async => d,
                      onSearchHistory: () {},
                      onDiagnostics: () {},
                      onRemove: (_) async {},
                    );
            },
        buildConversation: (_, _) => const _SampleChat(),
        buildFiles: (_, _) => const Center(child: Text('文件')),
        buildApps: (_, _) => const Center(child: Text('应用')),
        buildPlace: (_, _, _, {titleKey, controlsKey}) =>
            const SizedBox.shrink(),
        // Taller than a window: shows where a sheet stops and that its buttons
        // stay in reach.
        buildSelfPanel: (context) => ShellSheetBody(
          content: const SizedBox(height: 900),
          actions: Align(
            alignment: Alignment.centerRight,
            child: ShellButton(
              label: 'Done',
              kind: ShellButtonKind.primary,
              onTap: () => Navigator.of(context).pop(),
            ),
          ),
        ),
        buildCard: (_, _, _) => const SizedBox.shrink(),
        paletteItems: (_) => const [],
        searchMessages: (_, _) async => const [],
      ),
    ),
  );
}

/// A conversation with a field to type a draft in, to see it survive a fold.
class _SampleChat extends StatelessWidget {
  const _SampleChat();

  @override
  Widget build(BuildContext context) {
    final touch = WhisperLayout.touchPlatform;
    final compact = WhisperLayout.of(context).compact;
    return LayoutBuilder(
      builder: (context, box) => Stack(
        children: [
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 92),
            children: [
              for (final (text, mine) in const [
                ('发版说明改好了，帮我看一眼。主要动了挂载和共享链接两节，西语还没翻，你先看中文的就行。', false),
                ('不急', false),
                ('好', true),
              ]) ...[
                WhisperBubble(text: text, mine: mine, touch: touch),
                const SizedBox(height: 6),
              ],
            ],
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: compact ? 24 : 16,
            child: SafeArea(
              top: false,
              child: Center(
                child: SizedBox(
                  width: compact
                      ? box.maxWidth - 36
                      : (box.maxWidth - 48).clamp(0, 860).toDouble(),
                  child: const Material(
                    type: MaterialType.transparency,
                    child: TextField(
                      key: ValueKey('preview-draft'),
                      decoration: InputDecoration(
                        hintText: '发给 iMac',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
