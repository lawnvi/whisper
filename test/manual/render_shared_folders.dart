// 共享与权限 in the desktop's settings with its 「共享的目录」 row, the page
// under it (the system disk and two others, two folders left out, one of
// them not there now), and a folder's menu, in both themes.
// A layout overflow fails the test on its own.
//
// To look at them:
//   WHISPER_RENDER_OUT=/some/dir flutter test --no-pub test/manual/render_shared_folders.dart

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/new_ui/settings/settings_controls.dart';
import 'package:whisper/new_ui/settings/settings_panel.dart';
import 'package:whisper/new_ui/settings/settings_shared_folders.dart';
import 'package:whisper/remote_files/fs_paths.dart';
import 'package:whisper/remote_files/fs_share_policy.dart';
import 'package:whisper/remote_files/fs_shared_folders.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/theme/whisper_ui.dart';

import '../support/golden_support.dart';

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

/// Lets real file I/O started in the test's fake-async zone finish.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(loadGoldenFonts);

  for (final brightness in Brightness.values) {
    testWidgets('shared folders, ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(900, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final home = Directory.systemTemp.createTempSync('whisper-share-');
      addTearDown(() => home.deleteSync(recursive: true));
      final private = Directory(p.join(home.path, 'Documents', '私人'))
        ..createSync(recursive: true);
      SharedPreferences.setMockInitialValues({
        'remote_files.shared_disks': ['/Volumes/KINGSTON'],
        'remote_files.excluded_folders': [private.path, '/Volumes/SanDisk/照片'],
      });
      final homeRoot = FsRoot(
        id: 'home',
        directory: home.path,
        shortcuts: const [
          FsShortcut(kind: 'desktop', path: 'Desktop'),
          FsShortcut(kind: 'documents', path: 'Documents'),
          FsShortcut(kind: 'downloads', path: 'Downloads'),
          FsShortcut(kind: 'pictures', path: 'Pictures'),
          FsShortcut(kind: 'movies', path: 'Movies'),
          FsShortcut(kind: 'music', path: 'Music'),
        ],
      );
      final folders = FsSharedFolders(
        protectedAreas: () async => FsProtectedAreas(home: home.path),
        defaultRoots: () => [homeRoot],
        systemDisk: () async => const FsRoot(
          id: 'system',
          directory: '/',
          kind: FsRootKind.volume,
          label: 'Macintosh HD',
        ),
        systemFolders: (_) async => const [],
        disks: () async => volumeRoots(const [
          (path: '/Volumes/Data', label: '', removable: false),
          (path: '/Volumes/KINGSTON', label: '', removable: true),
        ]),
      );
      await tester.runAsync(folders.refresh);

      Future<void> show(Widget Function(AppLocalizations l10n) body) async {
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: brightness == Brightness.light
                ? AppTheme.lightTheme
                : AppTheme.darkTheme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('zh'),
            // Around the navigator: the menu is a route of its own.
            builder: (context, child) =>
                RepaintBoundary(key: const ValueKey('shot'), child: child),
            home: Builder(
              builder: (context) {
                final l10n = AppLocalizations.of(context)!;
                return ColoredBox(
                  color: context.wc.content,
                  child: SettingsScope(
                    touch: false,
                    page: false,
                    child: SettingsPanelFrame(
                      nav: SettingsPanelNav(
                        title: l10n.setting,
                        entries: [
                          (
                            title: l10n.shellSettingsGeneral,
                            glyph: null,
                            color: WhisperSettingsIcons.general,
                          ),
                          (
                            title: l10n.shellSettingsConnection,
                            glyph: WhisperGlyph.globe,
                            color: context.wc.accent,
                          ),
                          (
                            title: l10n.shellSettingsSystem,
                            glyph: WhisperGlyph.gear,
                            color: WhisperSettingsIcons.system,
                          ),
                          (
                            title: l10n.shellSettingsSharing,
                            glyph: WhisperGlyph.link,
                            color: WhisperSettingsIcons.sharing,
                          ),
                          (
                            title: l10n.shellSettingsNotifications,
                            glyph: WhisperGlyph.bell,
                            color: WhisperSettingsIcons.notifications,
                          ),
                          (
                            title: l10n.shellSettingsAbout,
                            glyph: WhisperGlyph.info,
                            color: WhisperSettingsIcons.about,
                          ),
                        ],
                        selected: 3,
                        onSelect: (_) {},
                      ),
                      body: body(l10n),
                      bodyKey: const ValueKey('body'),
                      closeLabel: l10n.close,
                      onClose: () {},
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await _settle(tester);
      }

      await show(
        (l10n) => SettingsPanelPage(
          title: l10n.shellSettingsSharing,
          children: [
            SettingsGroup(
              children: [
                SettingsSwitchRow(
                  title: l10n.windowStreamShareSetting,
                  value: true,
                  onChanged: (_) {},
                ),
                SharedFoldersRow(folders: folders, onTap: () {}),
                SettingsSwitchRow(
                  title: l10n.shellSettingsClipboardSync,
                  value: false,
                  onChanged: (_) {},
                ),
              ],
            ),
          ],
        ),
      );
      await _render(tester, 'shared-folders-row-${brightness.name}');

      await show(
        (l10n) => SharedFoldersPage(
          folders: folders,
          back: () {},
          backLabel: l10n.shellSettingsSharing,
        ),
      );
      expect(find.text('找不到'), findsOneWidget);
      await _render(tester, 'shared-folders-page-${brightness.name}');

      await tester.tap(find.text('私人'));
      await _settle(tester);
      expect(find.text('恢复共享'), findsOneWidget);
      await _render(tester, 'shared-folders-menu-${brightness.name}');
    });
  }
}
