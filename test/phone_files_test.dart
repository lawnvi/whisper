// surfaces.md「文件」on a phone, what it shows and what it does. A layout overflow
// fails a test on its own.
//
// To look at them next to docs/design/reference/:
//   WHISPER_RENDER_DIR=/some/dir flutter test --no-pub \
//     --dart-define=WHISPER_NEW_UI=true test/phone_files_test.dart

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/l10n/app_localizations_zh.dart';
import 'package:whisper/new_ui/files/phone_files.dart';
import 'package:whisper/page/remote_files/files_model.dart';
import 'package:whisper/page/remote_files/remote_files_page.dart';
import 'package:whisper/remote_files/fs_browser.dart';
import 'package:whisper/remote_files/fs_client.dart';
import 'package:whisper/remote_files/fs_host_files.dart';
import 'package:whisper/remote_files/fs_paths.dart';
import 'package:whisper/remote_files/fs_copies.dart';
import 'package:whisper/share_links/share_link_store.dart';

import 'support/phone_shots.dart';

const _mb = 1024 * 1024;

FsEntry _dir(String name) =>
    FsEntry(name: name, isDir: true, size: 0, modifiedMs: 1);
FsEntry _file(String name, int size, {bool hidden = false}) => FsEntry(
  name: name,
  isDir: false,
  size: size,
  modifiedMs: 1,
  hidden: hidden,
);

/// Another device's files, without a connection.
class _Browser implements FsBrowser {
  _Browser(this.folders, {this.readOnly = false});

  final Map<String, List<FsEntry>> folders;
  bool fails = false;

  @override
  final bool readOnly;

  @override
  bool get isLocal => false;

  @override
  bool get hasTrash => false;

  @override
  List<FsPlace> get places => const [
    FsPlace(root: 'home', path: '', kind: 'root'),
    FsPlace(root: 'home', path: '下载', kind: 'downloads'),
  ];

  @override
  Future<FsPage> list(
    String root,
    String path, {
    int offset = 0,
    bool showHidden = false,
  }) async {
    if (fails) throw const RemoteFsException('nope');
    final all = (folders[path] ?? const <FsEntry>[])
        .where((entry) => showHidden || !entry.hidden)
        .toList();
    return FsPage(entries: all, total: all.length, offset: 0);
  }

  @override
  Future<Uint8List?> thumbnail(String root, String path) async => null;

  final removed = <String>[];

  @override
  Future<String> mkdir(String root, String parent, String name) async => name;

  @override
  Future<String> rename(String root, String path, String name) async => name;

  @override
  Future<void> remove(
    String root,
    String path, {
    bool permanent = false,
  }) async => removed.add(path);
}

final _imacFiles = <String, List<FsEntry>>{
  '': [
    _dir('文稿'),
    _dir('下载'),
    _file('设计稿 v3.pdf', (24.6 * _mb).round()),
    _file('Whisper.dmg', 118 * _mb),
    _file('周报.numbers', 412 * 1024),
  ],
  '文稿': [_file('合同.pdf', 1 * _mb)],
  '下载': const [],
};

/// Records instead of starting transfers.
class _Actions extends FilesActions {
  _Actions({required super.controller, required super.context});

  final copied = <(List<FilesItem>, FilesLocation)>[];

  @override
  Future<bool> copy(List<FilesItem> items, FilesLocation target) async {
    copied.add((items, target));
    return true;
  }
}

class _World {
  _World(this.controller, this.local);

  final FilesController controller;
  final Directory local;
  late _Actions actions;
}

Future<_World> _world(
  WidgetTester tester, {
  Set<String> connected = const {'imac', 'mi'},
  _Browser? imac,
  bool atImac = true,
  void Function(FilesController)? setup,
}) async {
  SharedPreferences.setMockInitialValues({});
  late _World world;
  await tester.runAsync(() async {
    final local = await Directory.systemTemp.createTemp('whisper-phone-');
    addTearDown(() => local.delete(recursive: true));
    await Directory(p.join(local.path, '相册')).create();
    await File(p.join(local.path, '笔记.txt')).writeAsString('hello');
    final controller = FilesController(
      local: LocalFsBrowser(
        files: FsHostFiles(
          resolver: FsPathResolver([
            FsRoot(
              id: 'home',
              directory: local.path,
              shortcuts: const [FsShortcut(kind: 'downloads', path: '相册')],
            ),
          ]),
        ),
      ),
      peers: FilesPeers(
        connected: () => connected,
        canBrowse: (_) => true,
        describe: (id) => switch (id) {
          'imac' => (name: 'iMac', platform: 'macos'),
          _ => (name: 'Xiaomi 16', platform: 'android'),
        },
      ),
      copyList: FileCopies(),
    );
    addTearDown(controller.dispose);
    for (var i = 0; i < 200 && controller.entries.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (atImac) {
      final device = controller.deviceById('imac')!;
      device
        ..browser = imac ?? _Browser(_imacFiles)
        ..state = FilesDeviceState.ready;
      await controller.go(const FilesLocation('imac', 'home', ''));
    }
    setup?.call(controller);
    world = _World(controller, local);
  });
  world.actions = _Actions(
    controller: world.controller,
    context: () => tester.element(find.byType(PhoneFilesView)),
  );
  return world;
}

Widget _view(_World world) =>
    PhoneFilesView(controller: world.controller, actions: world.actions);

const _capsule = ValueKey('files-capsule');

void main() {
  setUpAll(loadPhoneFonts);
  final l10n = AppLocalizationsZh();

  group('the list', () {
    testWidgets('rows of 48, no lines, only the size', (tester) async {
      final world = await _world(tester);
      await pumpPhone(tester, _view(world));
      expect(find.text(l10n.shellTabFiles), findsOneWidget);
      expect(find.text('iMac'), findsOneWidget);
      expect(find.text(l10n.shellFilesCount(5)), findsOneWidget);
      expect(find.text('文稿'), findsOneWidget);
      expect(find.text('24.6 MB'), findsOneWidget);

      final rows = find.byType(PhoneFileRow);
      expect(rows, findsNWidgets(5));
      for (var i = 0; i < 5; i++) {
        expect(tester.getSize(rows.at(i)).height, 48);
        expect(tester.getSize(rows.at(i)).width, 380);
      }
      // The first row starts where the path row and its 8 end.
      expect(tester.getTopLeft(rows.first).dy, 44 + 50 + 48 + 8);
      // Folders say nothing about their size.
      expect(
        find.descendant(of: rows.first, matching: find.byType(Text)),
        findsOneWidget,
      );
      expect(find.byType(Divider), findsNothing);
      expect(find.text(l10n.shareLinksTitle), findsNothing);
    });

    testWidgets('a folder opens, the arrow in the path row goes up', (
      tester,
    ) async {
      final world = await _world(tester);
      await pumpPhone(tester, _view(world));
      await tester.tap(find.text('文稿'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await phoneSettle(tester);
      expect(world.controller.location!.path, '文稿');
      expect(find.text('合同.pdf'), findsOneWidget);
      expect(tester.getTopLeft(find.byType(PhoneFileRow)).dy, 44 + 50 + 48 + 8);
      await tester.tap(find.bySemanticsLabel(l10n.back).last);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await phoneSettle(tester);
      expect(world.controller.location!.path, '');
    });

    testWidgets('an empty folder says so', (tester) async {
      final world = await _world(tester);
      await tester.runAsync(
        () => world.controller.go(const FilesLocation('imac', 'home', '下载')),
      );
      await pumpPhone(tester, _view(world));
      expect(find.text(l10n.remoteFilesEmptyFolder), findsOneWidget);
    });

    testWidgets('a folder that fails says so and tries again', (tester) async {
      final browser = _Browser(_imacFiles);
      final world = await _world(tester, imac: browser);
      browser.fails = true;
      await tester.runAsync(() => world.controller.reload());
      await pumpPhone(tester, _view(world));
      expect(find.text(l10n.remoteFilesFailed), findsOneWidget);
      browser.fails = false;
      await tester.tap(find.text(l10n.windowStreamRetry));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await phoneSettle(tester);
      expect(find.text('文稿'), findsOneWidget);
    });
  });

  group('selecting', () {
    testWidgets('a tap on a file raises the capsule, nothing moves', (
      tester,
    ) async {
      final world = await _world(tester);
      await pumpPhone(tester, _view(world));
      final row = find.byType(PhoneFileRow).at(2);
      final before = tester.getTopLeft(row);
      await tester.tap(find.text('设计稿 v3.pdf'));
      await phoneSettle(tester);
      expect(find.byKey(_capsule), findsOneWidget);
      expect(tester.getTopLeft(row), before);
      expect(world.controller.selection, {'设计稿 v3.pdf'});
      // Another device's: to here first, then 发到…, then away.
      expect(find.text(l10n.shellFilesCopyHere), findsOneWidget);
      expect(find.text(l10n.shellFilesSendTo), findsOneWidget);
      expect(find.text(l10n.shareLinksTitle), findsNothing);
      // Everything in it is 48 to hit.
      for (final key in const [
        'files-copy-here',
        'files-send-to',
        'files-unselect',
      ]) {
        expect(
          tester.getSize(find.byKey(ValueKey(key))).height,
          48,
          reason: key,
        );
      }
      // At the bottom, 24 from the edge, 54 high.
      final capsule = tester.getRect(find.byKey(_capsule));
      expect(capsule.bottom, closeTo(780 - 24, .5));
      expect(capsule.height, closeTo(54, .5));
      expect(capsule.center.dx, closeTo(190, .5));

      // Another tap lets go.
      await tester.tap(find.text('设计稿 v3.pdf'));
      await phoneSettle(tester);
      expect(find.byKey(_capsule), findsNothing);
    });

    testWidgets('this device\'s files go out, and share links are theirs', (
      tester,
    ) async {
      final world = await _world(tester, atImac: false);
      await pumpPhone(tester, _view(world));
      await tester.tap(find.text('笔记.txt'));
      await phoneSettle(tester);
      expect(find.text(l10n.shellFilesCopyHere), findsNothing);
      expect(find.text(l10n.shellFilesSendTo), findsOneWidget);
      expect(
        find.text(l10n.shareLinksTitle),
        shareLinksSupported() ? findsOneWidget : findsNothing,
      );
    });

    testWidgets('拷到这台 goes to this device\'s downloads', (tester) async {
      final world = await _world(tester);
      await pumpPhone(tester, _view(world));
      await tester.tap(find.text('周报.numbers'));
      await phoneSettle(tester);
      await tester.tap(find.byKey(const ValueKey('files-copy-here')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await phoneSettle(tester);
      expect(world.actions.copied, hasLength(1));
      final (items, where) = world.actions.copied.single;
      expect(items.single.name, '周报.numbers');
      expect(where.deviceId, FilesDevice.localId);
      expect(where.path, '相册');
      expect(find.byKey(_capsule), findsNothing);
    });

    testWidgets('picking several: all, how many, done', (tester) async {
      final world = await _world(tester);
      await pumpPhone(tester, _view(world));
      await tester.tap(find.byKey(const ValueKey('files-more')));
      await phoneSettle(tester);
      await tester.tap(find.text(l10n.remoteFilesSelect));
      await phoneSettle(tester);
      await tester.tap(find.text('设计稿 v3.pdf'));
      await tester.tap(find.text('文稿'));
      await phoneSettle(tester);
      expect(world.controller.selection, {'设计稿 v3.pdf', '文稿'});
      expect(find.text(l10n.remoteFilesSelected(2)), findsOneWidget);
      expect(
        find.byKey(const ValueKey('files-selection-more')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('files-select-all')));
      await phoneSettle(tester);
      expect(world.controller.selection, hasLength(5));
      await tester.tap(find.byKey(const ValueKey('files-select-done')));
      await phoneSettle(tester);
      expect(world.controller.selection, isEmpty);
      expect(find.byKey(_capsule), findsNothing);
    });

    testWidgets('the capsule\'s sheet has what does not fit in it', (
      tester,
    ) async {
      final world = await _world(tester);
      await pumpPhone(tester, _view(world));
      await tester.tap(find.byKey(const ValueKey('files-more')));
      await phoneSettle(tester);
      await tester.tap(find.text(l10n.remoteFilesSelect));
      await phoneSettle(tester);
      await tester.tap(find.text('Whisper.dmg'));
      await phoneSettle(tester);
      await tester.tap(find.byKey(const ValueKey('files-selection-more')));
      await phoneSettle(tester);
      expect(find.text(l10n.remoteFilesCopy), findsOneWidget);
      expect(find.text(l10n.remoteFilesCopyToMenu), findsOneWidget);
      expect(find.text(l10n.remoteFilesRename), findsOneWidget);
      expect(find.text(l10n.remoteFilesDelete), findsOneWidget);
    });
  });

  group('long press', () {
    testWidgets('opens a sheet with all that can be done', (tester) async {
      final world = await _world(tester);
      await pumpPhone(tester, _view(world));
      await tester.longPress(find.text('Whisper.dmg'));
      await phoneSettle(tester);
      expect(find.byKey(const ValueKey('phone-sheet-grab')), findsOneWidget);
      expect(find.text('Whisper.dmg'), findsNWidgets(2));
      for (final label in [
        l10n.remoteFilesCopy,
        l10n.shellFilesCopyHere,
        l10n.shellFilesSendTo,
        l10n.remoteFilesCopyToMenu,
        l10n.remoteFilesRename,
        l10n.remoteFilesDelete,
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
        expect(tester.getSize(find.text(label)).height, lessThanOrEqualTo(48));
      }
      expect(find.text(l10n.remoteFilesOpen), findsNothing);
    });

    testWidgets('a folder can be opened from it', (tester) async {
      final world = await _world(tester);
      await pumpPhone(tester, _view(world));
      await tester.longPress(find.text('文稿'));
      await phoneSettle(tester);
      expect(find.text(l10n.remoteFilesOpen), findsOneWidget);
      await tester.tap(find.text(l10n.remoteFilesOpen));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await phoneSettle(tester);
      expect(world.controller.location!.path, '文稿');
    });

    testWidgets('below the rows: the folder itself', (tester) async {
      final world = await _world(tester);
      await pumpPhone(tester, _view(world));
      await tester.longPressAt(const Offset(190, 600));
      await phoneSettle(tester);
      expect(find.byKey(const ValueKey('phone-sheet-grab')), findsOneWidget);
      expect(find.text(l10n.remoteFilesNewFolder), findsOneWidget);
      expect(find.text(l10n.remoteFilesSelect), findsOneWidget);
      await tester.tap(find.text(l10n.remoteFilesSelect));
      await phoneSettle(tester);
      expect(find.byKey(const ValueKey('files-select-all')), findsOneWidget);
    });

    testWidgets('read only: nothing to change, nothing offered', (
      tester,
    ) async {
      final world = await _world(
        tester,
        imac: _Browser(_imacFiles, readOnly: true),
      );
      await pumpPhone(tester, _view(world));
      await tester.longPress(find.text('Whisper.dmg'));
      await phoneSettle(tester);
      expect(find.text(l10n.remoteFilesRename), findsNothing);
      expect(find.text(l10n.remoteFilesDelete), findsNothing);
      expect(find.text(l10n.remoteFilesCopy), findsOneWidget);
    });

    testWidgets('rename asks in a sheet', (tester) async {
      final world = await _world(tester);
      await pumpPhone(tester, _view(world));
      await tester.longPress(find.text('Whisper.dmg'));
      await phoneSettle(tester);
      await tester.tap(find.text(l10n.remoteFilesRename));
      await phoneSettle(tester);
      expect(find.byKey(const ValueKey('files-name-field')), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('files-name-field')),
        'Whisper 2.dmg',
      );
      await tester.tap(find.byKey(const ValueKey('files-name-confirm')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await phoneSettle(tester);
      expect(find.byKey(const ValueKey('files-name-field')), findsNothing);
    });

    testWidgets('delete asks first, on a device without a trash', (
      tester,
    ) async {
      final browser = _Browser(_imacFiles);
      final world = await _world(tester, imac: browser);
      await pumpPhone(tester, _view(world));
      await tester.longPress(find.text('Whisper.dmg'));
      await phoneSettle(tester);
      await tester.tap(find.text(l10n.remoteFilesDelete));
      await phoneSettle(tester);
      expect(
        find.byKey(const ValueKey('files-delete-confirm')),
        findsOneWidget,
      );
      expect(browser.removed, isEmpty);
      await tester.tap(find.byKey(const ValueKey('files-delete-confirm')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await phoneSettle(tester);
      expect(browser.removed, ['Whisper.dmg']);
    });

    testWidgets('拷贝 then 粘贴, from the more menu', (tester) async {
      final world = await _world(tester);
      await pumpPhone(tester, _view(world));
      await tester.longPress(find.text('Whisper.dmg'));
      await phoneSettle(tester);
      await tester.tap(find.text(l10n.remoteFilesCopy));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await phoneSettle(tester);
      expect(world.controller.clipboard.single.name, 'Whisper.dmg');
      await tester.tap(find.byKey(const ValueKey('files-more')));
      await phoneSettle(tester);
      expect(find.text(l10n.remoteFilesPaste(1)), findsOneWidget);
    });

    testWidgets('拷贝到… is a walk to the folder, with its own capsule', (
      tester,
    ) async {
      final world = await _world(tester);
      await pumpPhone(tester, _view(world));
      await tester.longPress(find.text('Whisper.dmg'));
      await phoneSettle(tester);
      await tester.tap(find.text(l10n.remoteFilesCopyToMenu));
      await phoneSettle(tester);
      expect(find.byKey(const ValueKey('files-copy-bar')), findsOneWidget);
      // Same device: it says so and will not go.
      expect(find.text(l10n.remoteFilesSameDevice), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('files-copy-go')));
      await tester.pump();
      expect(world.actions.copied, isEmpty);
      // This device instead.
      await tester.tap(find.byKey(const ValueKey('files-location')));
      await phoneSettle(tester);
      await tester.tap(find.text(l10n.remoteFilesThisDevice));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await phoneSettle(tester);
      await tester.tap(find.byKey(const ValueKey('files-copy-go')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await phoneSettle(tester);
      expect(world.actions.copied.single.$2.deviceId, FilesDevice.localId);
      expect(find.byKey(const ValueKey('files-copy-bar')), findsNothing);
    });
  });

  group('the path row', () {
    testWidgets('location: this device first, then others, with their places', (
      tester,
    ) async {
      final world = await _world(tester);
      await pumpPhone(tester, _view(world));
      await tester.tap(find.byKey(const ValueKey('files-location')));
      await phoneSettle(tester);
      final self = tester.getTopLeft(
        find.byKey(const ValueKey('files-location-local')),
      );
      final imac = tester.getTopLeft(
        find.byKey(const ValueKey('files-location-imac')),
      );
      final mi = tester.getTopLeft(
        find.byKey(const ValueKey('files-location-mi')),
      );
      expect(self.dy, lessThan(imac.dy));
      expect(imac.dy, lessThan(mi.dy));
      expect(
        tester
            .getSize(find.byKey(const ValueKey('files-location-imac')))
            .height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.text(l10n.remoteFilesPlaceDownloads).last);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await phoneSettle(tester);
      expect(world.controller.location!.path, '下载');
    });

    testWidgets('more: everything from the old page, and transfers', (
      tester,
    ) async {
      final world = await _world(tester);
      await pumpPhone(tester, _view(world));
      await tester.tap(find.byKey(const ValueKey('files-more')));
      await phoneSettle(tester);
      for (final label in [
        l10n.remoteFilesSelect,
        l10n.remoteFilesNewFolder,
        l10n.remoteFilesColumnName,
        l10n.remoteFilesColumnModified,
        l10n.remoteFilesColumnSize,
        l10n.remoteFilesColumnKind,
        l10n.remoteFilesShowHidden,
        l10n.remoteFilesRefresh,
        l10n.remoteFilesTransfers,
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.tap(find.text(l10n.remoteFilesColumnSize));
      await phoneSettle(tester);
      expect(world.controller.sort, FilesSort.size);
      await tester.tap(find.byKey(const ValueKey('files-more')));
      await phoneSettle(tester);
      await tester.tap(find.text(l10n.remoteFilesShowHidden));
      await phoneSettle(tester);
      expect(world.controller.showHidden, isTrue);
      await tester.tap(find.byKey(const ValueKey('files-more')));
      await phoneSettle(tester);
      await tester.tap(find.text(l10n.remoteFilesTransfers));
      await phoneSettle(tester);
      expect(find.text(l10n.remoteFilesTransfers), findsOneWidget);
      expect(find.byKey(const ValueKey('files-location')), findsNothing);
      // The bar's arrow comes back from there, and does not leave.
      await tester.tap(find.bySemanticsLabel(l10n.back).first);
      await phoneSettle(tester);
      expect(find.byKey(const ValueKey('files-location')), findsOneWidget);
    });

    testWidgets('search filters and moves nothing', (tester) async {
      final world = await _world(tester);
      await pumpPhone(tester, _view(world));
      final row = find.byType(PhoneFileRow).first;
      final before = tester.getTopLeft(row);
      await tester.tap(find.byKey(const ValueKey('files-filter')));
      await phoneSettle(tester);
      expect(tester.getTopLeft(row), before);
      await tester.enterText(
        find.byKey(const ValueKey('files-filter-field')),
        'whisper',
      );
      await phoneSettle(tester);
      expect(find.byType(PhoneFileRow), findsOneWidget);
      expect(find.text('Whisper.dmg'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('files-filter')));
      await phoneSettle(tester);
      expect(world.controller.query, '');
      expect(find.byType(PhoneFileRow), findsNWidgets(5));
    });

    testWidgets('every control is at least 48 to hit', (tester) async {
      final world = await _world(tester);
      await pumpPhone(tester, _view(world));
      for (final key in const [
        'files-location',
        'files-filter',
        'files-more',
      ]) {
        expect(
          tester.getSize(find.byKey(ValueKey(key))).height,
          greaterThanOrEqualTo(48),
          reason: key,
        );
      }
    });
  });

  group('发到…', () {
    testWidgets('this device\'s file: connected devices, then a copy', (
      tester,
    ) async {
      final world = await _world(
        tester,
        atImac: false,
        setup: (controller) {
          controller.deviceById('imac')!
            ..browser = _Browser(_imacFiles)
            ..state = FilesDeviceState.ready;
        },
      );
      await pumpPhone(tester, _view(world));
      await tester.tap(find.text('笔记.txt'));
      await phoneSettle(tester);
      await tester.tap(find.byKey(const ValueKey('files-send-to')));
      await phoneSettle(tester);
      expect(find.text(l10n.pickerSendFile('笔记.txt')), findsOneWidget);
      expect(find.byKey(const ValueKey('device-picker-imac')), findsOneWidget);
      expect(find.byKey(const ValueKey('device-picker-mi')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('device-picker-imac'))).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.byKey(const ValueKey('device-picker-imac')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await phoneSettle(tester);
      final (_, where) = world.actions.copied.single;
      expect(where.deviceId, 'imac');
      expect(where.path, '下载');
    });

    testWidgets('a device not asked yet: asks, then a folder is picked', (
      tester,
    ) async {
      RemoteFilesClient.sender = (peerId, message) async => true;
      RemoteFilesClient.localPeerId = (_) => 'me';
      final world = await _world(tester, atImac: false);
      await pumpPhone(tester, _view(world));
      await tester.tap(find.text('笔记.txt'));
      await phoneSettle(tester);
      await tester.tap(find.byKey(const ValueKey('files-send-to')));
      await phoneSettle(tester);
      await tester.tap(find.byKey(const ValueKey('device-picker-mi')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await phoneSettle(tester);
      expect(find.byKey(const ValueKey('files-copy-bar')), findsOneWidget);
      expect(
        world.controller.deviceById('mi')!.state,
        FilesDeviceState.waiting,
      );
      expect(
        find.text(l10n.shellFilesAskOnDevice('Xiaomi 16')),
        findsOneWidget,
      );
      await tester.tap(find.text(l10n.cancel).first);
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await phoneSettle(tester);
    });

    testWidgets('another device\'s file: this device\'s places', (
      tester,
    ) async {
      final world = await _world(tester);
      await pumpPhone(tester, _view(world));
      await tester.tap(find.text('Whisper.dmg'));
      await phoneSettle(tester);
      await tester.tap(find.byKey(const ValueKey('files-send-to')));
      await phoneSettle(tester);
      expect(find.text(l10n.pickerSendFile('Whisper.dmg')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('device-picker-1')));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await phoneSettle(tester);
      final (_, where) = world.actions.copied.single;
      expect(where.deviceId, FilesDevice.localId);
      expect(where.path, '相册');
    });
  });

  group('states', () {
    testWidgets('waiting, with the device and a way out', (tester) async {
      final world = await _world(tester, atImac: false);
      world.controller.deviceById('imac')!.state = FilesDeviceState.waiting;
      await tester.runAsync(() async {
        await world.controller.go(const FilesLocation('imac', '', ''));
      });
      await pumpPhone(tester, _view(world));
      expect(find.text(l10n.shellFilesAskOnDevice('iMac')), findsOneWidget);
      expect(find.text(l10n.cancel), findsOneWidget);
    });

    for (final (state, title) in [
      (FilesDeviceState.denied, l10n.shellFilesDenied('iMac')),
      (FilesDeviceState.noAnswer, l10n.remoteFilesNoAnswer('iMac')),
      (FilesDeviceState.offline, l10n.shellNotConnected('iMac')),
      (FilesDeviceState.idle, l10n.remoteFilesNotAsked('iMac')),
      (FilesDeviceState.unsupported, l10n.remoteFilesUnsupported('iMac')),
    ]) {
      testWidgets('$state', (tester) async {
        final world = await _world(tester, atImac: false);
        world.controller.deviceById('imac')!.state = state;
        await tester.runAsync(() async {
          await world.controller.go(const FilesLocation('imac', '', ''));
        });
        await pumpPhone(tester, _view(world));
        expect(find.text(title), findsOneWidget);
      });
    }
  });

  group('every state fits', () {
    for (final (locale, size, scale, brightness) in phoneMatrix) {
      final tag =
          '${locale.languageCode} ${size.width.round()} ${scale}x ${brightness.name}';
      testWidgets(tag, (tester) async {
        final world = await _world(tester);
        await pumpPhone(
          tester,
          _view(world),
          locale: locale,
          size: size,
          textScale: scale,
          brightness: brightness,
        );
        expect(tester.takeException(), isNull);
        // The capsule.
        await tester.tap(find.text('Whisper.dmg'));
        await phoneSettle(tester);
        expect(tester.takeException(), isNull);
        // Its picker.
        await tester.tap(find.byKey(const ValueKey('files-send-to')));
        await phoneSettle(tester);
        expect(tester.takeException(), isNull);
        await tester.tapAt(const Offset(10, 60));
        await phoneSettle(tester);
        // The long press sheet.
        await tester.longPress(find.text('周报.numbers'));
        await phoneSettle(tester);
        expect(tester.takeException(), isNull);
        await tester.tapAt(const Offset(10, 60));
        await phoneSettle(tester);
        // The more menu.
        await tester.tap(find.byKey(const ValueKey('files-more')));
        await phoneSettle(tester);
        expect(tester.takeException(), isNull);
        await tester.tapAt(const Offset(10, 60));
        await phoneSettle(tester);
        // The location menu.
        await tester.tap(find.byKey(const ValueKey('files-location')));
        await phoneSettle(tester);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('pictures', () {
    testWidgets('next to the references', (tester) async {
      await withPhoneShadows(() async {
        for (final brightness in Brightness.values) {
          final dark = brightness == Brightness.dark ? '-dark' : '';
          final world = await _world(tester);
          await pumpPhone(tester, _view(world), brightness: brightness);
          await phoneShot(
            tester,
            'files$dark',
            reference: dark.isEmpty ? 'phone-files.jpg' : null,
          );
          await tester.tap(find.text('设计稿 v3.pdf'));
          await phoneSettle(tester);
          await phoneShot(tester, 'files-selected$dark');
          await tester.tap(find.byKey(const ValueKey('files-send-to')));
          await phoneSettle(tester);
          await phoneShot(tester, 'files-picker$dark');
          await tester.tapAt(const Offset(10, 60));
          await phoneSettle(tester);
          await tester.tap(find.byKey(const ValueKey('files-unselect')));
          await phoneSettle(tester);
          await tester.longPress(find.text('Whisper.dmg'));
          await phoneSettle(tester);
          await phoneShot(tester, 'files-long-press$dark');
          await tester.tapAt(const Offset(10, 60));
          await phoneSettle(tester);
          await tester.tap(find.byKey(const ValueKey('files-location')));
          await phoneSettle(tester);
          await phoneShot(tester, 'files-location$dark');
          await tester.tapAt(const Offset(10, 760));
          await phoneSettle(tester);
          await tester.tap(find.byKey(const ValueKey('files-more')));
          await phoneSettle(tester);
          await phoneShot(tester, 'files-more$dark');
          await tester.tapAt(const Offset(10, 760));
          await phoneSettle(tester);
          await tester.tap(find.text('文稿'));
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await phoneSettle(tester);
          await phoneShot(tester, 'files-folder$dark');
          await tester.pumpWidget(const SizedBox.shrink());
          await phoneSettle(tester);
          final waiting = await _world(tester, atImac: false);
          waiting.controller.deviceById('imac')!.state =
              FilesDeviceState.waiting;
          await tester.runAsync(() async {
            await waiting.controller.go(const FilesLocation('imac', '', ''));
          });
          await pumpPhone(tester, _view(waiting), brightness: brightness);
          await phoneShot(tester, 'files-waiting$dark');
          await tester.pumpWidget(const SizedBox.shrink());
          await phoneSettle(tester);
        }
        final world = await _world(tester);
        await pumpPhone(
          tester,
          _view(world),
          locale: const Locale('es'),
          size: const Size(360, 720),
          textScale: 2,
        );
        await tester.tap(find.text('Whisper.dmg'));
        await phoneSettle(tester);
        await phoneShot(tester, 'files-es-200');
      });
    });
  });
}
