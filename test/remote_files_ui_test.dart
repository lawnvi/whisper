import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:super_clipboard/super_clipboard.dart' show WriteProgress;
import 'package:super_drag_and_drop/super_drag_and_drop.dart'
    show DropRegion, WidgetSnapshotter, WidgetSnapshotterState;
import 'package:super_native_extensions/raw_clipboard.dart' as raw;
// ignore: implementation_imports
import 'package:super_native_extensions/src/native/context.dart'
    show superNativeExtensionsContext;
// The channel context super_native_extensions talks through (a mock in
// tests).
// ignore: depend_on_referenced_packages
import 'package:irondash_message_channel/irondash_message_channel.dart'
    show MockMessageChannelContext, MockMethodChannel;
import 'package:whisper/page/remote_files/files_desktop.dart';
import 'package:whisper/page/remote_files/files_drag.dart';
import 'package:whisper/page/remote_files/files_icons.dart';
import 'package:whisper/page/remote_files/files_model.dart';
import 'package:whisper/page/remote_files/files_phone.dart';
import 'package:whisper/page/remote_files/files_transfers.dart';
import 'package:whisper/page/remote_files/remote_files_page.dart';
import 'package:whisper/remote_files/fs_browser.dart';
import 'package:whisper/remote_files/fs_client.dart';
import 'package:whisper/remote_files/fs_copies.dart';
import 'package:whisper/remote_files/fs_host.dart';
import 'package:whisper/remote_files/fs_host_files.dart';
import 'package:whisper/remote_files/fs_paths.dart';
import 'package:whisper/remote_files/fs_placement.dart';
import 'package:whisper/remote_files/fs_protocol.dart';
import 'package:whisper/theme/app_theme.dart';

class _FakeClipboard extends FilesSystemClipboard {
  List<String> contents = const [];

  @override
  Future<bool> write(List<String> paths) async {
    contents = paths;
    return true;
  }

  @override
  Future<List<String>> read() async => contents;

  @override
  Future<bool> clear() async {
    contents = const [];
    return true;
  }

  /// Files put there to be fetched when pasted (Explorer).
  List<FilesItem> fetched = const [];

  @override
  Future<bool> writeFetched(
    FilesController controller,
    List<FilesItem> items,
  ) async {
    contents = const [];
    fetched = items;
    return true;
  }
}

/// Reads paths back spelled its own way, as a platform may (a resolved
/// /var → /private/var, a different case…).
class _RespellingClipboard extends _FakeClipboard {
  @override
  Future<List<String>> read() async => [
    for (final path in contents) '/private$path',
  ];
}

/// What an app a file was dragged to gets.
class _AppFile implements EventSink<Uint8List> {
  final bytes = BytesBuilder();
  bool closed = false;
  Object? error;

  @override
  void add(Uint8List data) => bytes.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) => this.error = error;

  @override
  void close() => closed = true;
}

class _AppProgress implements WriteProgress {
  final fractions = <double>[];
  final cancel = ChangeNotifier();

  @override
  void updateProgress(double fraction) => fractions.add(fraction);

  @override
  Listenable get onCancel => cancel;
}

class _AllowGate extends FileBrowseGate {
  @override
  Future<FileBrowseDecision> ask(FileBrowseRequest request) async =>
      FileBrowseDecision.once;
}

FsHostFiles _files(String directory) => FsHostFiles(
  resolver: FsPathResolver([
    FsRoot(
      id: 'home',
      directory: directory,
      shortcuts: const [FsShortcut(kind: 'documents', path: 'Documents')],
    ),
  ]),
);

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

void main() {
  late Directory local;
  late Directory remote;
  final sent = <String>[];
  late FileBrowseHost host;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    local = await Directory.systemTemp.createTemp('whisper-files-local-');
    remote = await Directory.systemTemp.createTemp('whisper-files-remote-');
    for (final dir in [local, remote]) {
      await Directory(p.join(dir.path, 'Documents')).create();
      await Directory(p.join(dir.path, 'z folder')).create();
      await File(p.join(dir.path, 'b10.txt')).writeAsString('10');
      await File(p.join(dir.path, 'b2.txt')).writeAsString('2');
      await File(p.join(dir.path, 'photo.jpg')).writeAsBytes([1, 2, 3]);
    }
    // The other device, answering over a loopback "connection".
    host = FileBrowseHost(files: _files(remote.path), gate: _AllowGate());
    host.sender = (peerId, message) async {
      final copy = FileBrowseMessage.fromJson(
        jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
      );
      scheduleMicrotask(
        () => RemoteFilesClient.handle(copy, remotePeerId: 'phone'),
      );
      return true;
    };
    RemoteFilesClient.localPeerId = (_) => 'mac';
    RemoteFilesClient.sender = (peerId, message) async {
      final copy = FileBrowseMessage.fromJson(
        jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
      );
      scheduleMicrotask(
        () => host.handle(copy, remotePeerId: 'mac', deviceName: 'Mac'),
      );
      return true;
    };
    sent.clear();
    RemoteFilesClient.sendFile = (peerId, path, id) async {
      sent.add(p.basename(path));
      return true;
    };
  });

  tearDown(() async {
    await local.delete(recursive: true);
    await remote.delete(recursive: true);
  });

  FilesController controllerFor({String? focus}) => FilesController(
    focusPeerId: focus,
    local: LocalFsBrowser(files: _files(local.path)),
    peers: FilesPeers(
      connected: () => {'phone'},
      canBrowse: (_) => true,
      describe: (_) => (name: 'OnePlus', platform: 'android'),
    ),
  );

  test('lists folders first in natural order, filters by search', () async {
    final controller = controllerFor();
    addTearDown(controller.dispose);
    await _until(() => controller.entries.isNotEmpty);
    expect(controller.devices.map((d) => d.id), [FilesDevice.localId, 'phone']);
    expect(controller.entries.map((e) => e.name), [
      'Documents',
      'z folder',
      'b2.txt',
      'b10.txt',
      'photo.jpg',
    ]);
    controller.setSort(FilesSort.name);
    // Descending, folders still lead.
    expect(controller.entries.map((e) => e.name), [
      'z folder',
      'Documents',
      'photo.jpg',
      'b10.txt',
      'b2.txt',
    ]);
    controller.setQuery('B');
    expect(controller.entries.map((e) => e.name), ['b10.txt', 'b2.txt']);
  });

  test('another device asks first, then browses with history', () async {
    final controller = controllerFor();
    addTearDown(controller.dispose);
    await _until(() => controller.entries.isNotEmpty);
    final home = controller.location!;
    final phone = controller.deviceById('phone')!;
    expect(phone.state, FilesDeviceState.idle);

    await controller.open(phone);
    expect(phone.state, FilesDeviceState.ready);
    expect(controller.location!.deviceId, 'phone');
    expect(controller.entries, hasLength(5));
    await controller.openEntry(controller.entries.first);
    expect(controller.location!.path, 'Documents');

    await controller.back();
    expect(controller.location, FilesLocation('phone', 'home', ''));
    await controller.back();
    // The moment spent waiting for "允许" is not a stop in the history.
    expect(controller.location, home);
    expect(controller.canGoBack, isFalse);
    await controller.forward();
    expect(controller.location!.deviceId, 'phone');
  });

  test('copies only go between this device and another one', () async {
    final controller = controllerFor();
    addTearDown(controller.dispose);
    await _until(() => controller.entries.isNotEmpty);
    final here = controller.location!;
    controller.select('b2.txt');
    controller.copySelection();
    expect(controller.clipboard.single.path, 'b2.txt');
    expect(
      controller.copyProblem(controller.clipboard, here),
      FilesCopyProblem.sameDevice,
    );
    const phoneDocs = FilesLocation('phone', 'home', 'Documents');
    expect(
      controller.copyProblem(controller.clipboard, phoneDocs),
      FilesCopyProblem.notConnected,
    );
    await controller.open(controller.deviceById('phone')!);
    expect(controller.copyProblem(controller.clipboard, phoneDocs), isNull);
    expect(await controller.copy(controller.clipboard, phoneDocs), 1);
    expect(sent, ['b2.txt']);
    expect(controller.copies, hasLength(1));
  });

  Widget app(Widget child, {Size size = const Size(1100, 720)}) {
    return MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );
  }

  testWidgets('the desktop window looks and works like Finder', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late FilesController controller;
    await tester.runAsync(() async {
      controller = controllerFor();
      await _until(() => controller.entries.isNotEmpty);
    });
    final actions = FilesActions(
      controller: controller,
      context: () => tester.element(find.byType(FinderView)),
    );
    await tester.pumpWidget(
      app(FinderView(controller: controller, actions: actions)),
    );
    await tester.pump();
    expect(find.text('Favorites'), findsOneWidget);
    expect(find.text('Locations'), findsOneWidget);
    expect(find.text('OnePlus'), findsOneWidget);
    expect(find.text('Date Modified'), findsOneWidget);
    expect(find.text('JPG Image'), findsOneWidget);
    expect(find.text('5 items'), findsOneWidget);

    await tester.tap(find.text('b2.txt'));
    await tester.pump();
    expect(find.text('1 of 5 selected'), findsOneWidget);

    await tester.tap(find.byIcon(CupertinoIcons.square_grid_2x2));
    // The list fades into the icons, the selection kept.
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('Date Modified'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(controller.view, FilesView.icons);
    expect(find.text('Date Modified'), findsNothing);
    expect(find.text('1 of 5 selected'), findsOneWidget);

    // Copies have their own place, at the bottom of the sidebar.
    await tester.tap(find.text('Transfers').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.transfersOpen, isTrue);
    expect(find.byType(FilesTransfersList), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('pressing an item shows no drag picture until it moves', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late FilesController controller;
    await tester.runAsync(() async {
      controller = controllerFor();
      await _until(() => controller.entries.isNotEmpty);
    });
    final actions = FilesActions(
      controller: controller,
      context: () => tester.element(find.byType(FinderView)),
    );
    await tester.pumpWidget(
      app(FinderView(controller: controller, actions: actions)),
    );
    await tester.pump();
    final picture = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_DragFeedback',
    );

    final press = await tester.startGesture(
      tester.getCenter(find.text('z folder')),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryButton,
    );
    await tester.pump(const Duration(milliseconds: 500));
    // Held still: an ordinary click, no picture flashing up.
    expect(picture, findsNothing);
    expect(controller.selection, {'z folder'});

    await press.moveBy(const Offset(10, 0));
    await tester.pump();
    expect(picture, findsOneWidget);
    await press.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(picture, findsNothing);
    controller.dispose();
  });

  testWidgets('on a tablet a finger scrolls the list; holding picks up', (
    tester,
  ) async {
    // An iPad is wide enough for this layout: a swipe used to drag the item
    // under the finger instead of scrolling.
    await tester.binding.setSurfaceSize(const Size(1024, 768));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late FilesController controller;
    await tester.runAsync(() async {
      for (var i = 0; i < 60; i++) {
        await File(
          p.join(local.path, 'note ${i.toString().padLeft(2, '0')}.txt'),
        ).writeAsString('$i');
      }
      controller = controllerFor();
      await _until(() => controller.entries.length > 60);
    });
    final actions = FilesActions(
      controller: controller,
      context: () => tester.element(find.byType(FinderView)),
    );
    await tester.pumpWidget(
      app(
        FinderView(controller: controller, actions: actions),
        size: const Size(1024, 768),
      ),
    );
    await tester.pump();
    final picture = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_DragFeedback',
    );
    final item = find.text('note 05.txt');
    final before = tester.getTopLeft(item).dy;

    final swipe = await tester.startGesture(
      tester.getCenter(item),
      kind: PointerDeviceKind.touch,
    );
    for (var i = 0; i < 12; i++) {
      await swipe.moveBy(const Offset(0, -20));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(picture, findsNothing);
    await swipe.up();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(item).dy, lessThan(before - 150));
    // Nothing the finger passed over got selected.
    expect(controller.selection, isEmpty);

    await tester.tap(item, kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(controller.selection, {'note 05.txt'});

    // Held, the item is ready to go: moving on picks it up.
    final hold = await tester.startGesture(
      tester.getCenter(item),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 700));
    expect(picture, findsNothing);
    await hold.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(find.text('Copy'), findsNothing);
    expect(picture, findsOneWidget);
    await hold.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(picture, findsNothing);

    // Held and let go: the menu a right click opens (no right button on
    // a tablet).
    final menu = await tester.startGesture(
      tester.getCenter(item),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump(const Duration(milliseconds: 700));
    await menu.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Copy'), findsOneWidget);
    expect(picture, findsNothing);
    await tester.tapAt(const Offset(5, 5), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Copy'), findsNothing);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets(
    'a tablet selects several by taps and opens menus by holding',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1024, 768));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late FilesController controller;
      await tester.runAsync(() async {
        controller = controllerFor();
        await _until(() => controller.entries.isNotEmpty);
      });
      final actions = FilesActions(
        controller: controller,
        context: () => tester.element(find.byType(FinderView)),
      );
      await tester.pumpWidget(
        app(
          FinderView(controller: controller, actions: actions),
          size: const Size(1024, 768),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Select'), kind: PointerDeviceKind.touch);
      await tester.pump();
      expect(find.text('Done'), findsOneWidget);
      for (final name in ['b2.txt', 'photo.jpg', 'z folder']) {
        await tester.tap(find.text(name), kind: PointerDeviceKind.touch);
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(controller.selection, {'b2.txt', 'photo.jpg', 'z folder'});
      // A second tap takes one away again (no folder opens meanwhile).
      await tester.tap(find.text('z folder'), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 400));
      expect(controller.selection, {'b2.txt', 'photo.jpg'});
      expect(controller.location!.path, '');
      // Pressed through its handler: copies left by earlier tests show the
      // window's island over the middle of the toolbar.
      tester
          .widget<GestureDetector>(
            find
                .ancestor(
                  of: find.text('Done'),
                  matching: find.byType(GestureDetector),
                )
                .first,
          )
          .onTap!();
      await tester.pump();
      expect(find.text('Select'), findsOneWidget);

      // Held on the blank below the items: the folder's menu.
      final blank = await tester.startGesture(
        const Offset(700, 700),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump(const Duration(milliseconds: 700));
      await blank.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('New folder'), findsWidgets);
      expect(find.text('Select All'), findsOneWidget);
      await tester.tap(find.text('Select All'), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.selection.length, controller.entries.length);
      expect(find.text('Done'), findsOneWidget);
      expect(tester.takeException(), isNull);
      controller.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets('on macOS and Windows items are dragged by the system', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.binding.setSurfaceSize(const Size(1100, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late FilesController controller;
    await tester.runAsync(() async {
      controller = controllerFor();
      await _until(() => controller.entries.isNotEmpty);
      await controller.open(controller.deviceById('phone')!);
    });
    final actions = FilesActions(
      controller: controller,
      context: () => tester.element(find.byType(FinderView)),
    );
    await tester.pumpWidget(
      app(FinderView(controller: controller, actions: actions)),
    );
    await tester.pump();
    // Every item can leave the window; folders, the listing and the
    // sidebar take system drags (from here, Finder or Explorer).
    expect(find.byType(FilesSystemDragSource), findsNWidgets(5));
    expect(find.byType(DropRegion), findsWidgets);
    final picture = find.byWidgetPredicate(
      (widget) => widget.runtimeType.toString() == '_DragFeedback',
    );

    final press = await tester.startGesture(
      tester.getCenter(find.text('b2.txt')),
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryButton,
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(controller.selection, {'b2.txt'});
    // Held a while, then moved: still a drag, and not the window's own.
    await press.moveBy(const Offset(20, 0));
    await tester.pump();
    expect(picture, findsNothing);
    await press.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    controller.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a folder clicked in the list stays visible on the blue row', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late FilesController controller;
    await tester.runAsync(() async {
      controller = controllerFor();
      await _until(() => controller.entries.isNotEmpty);
    });
    final actions = FilesActions(
      controller: controller,
      context: () => tester.element(find.byType(FinderView)),
    );
    await tester.pumpWidget(
      app(FinderView(controller: controller, actions: actions)),
    );
    await tester.pump();
    await tester.tap(find.text('z folder'));
    await tester.pump();
    // Blue on blue the folder would vanish, looking like it flashed.
    final outlined = tester
        .widgetList<FsFileIcon>(find.byType(FsFileIcon))
        .where((icon) => icon.onAccent)
        .map((icon) => icon.entry.name);
    expect(outlined, ['z folder']);
    controller.dispose();
  });

  testWidgets('another device\'s places unfold only when asked', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late FilesController controller;
    await tester.runAsync(() async {
      controller = controllerFor();
      await _until(() => controller.entries.isNotEmpty);
      await controller.open(controller.deviceById('phone')!);
    });
    final actions = FilesActions(
      controller: controller,
      context: () => tester.element(find.byType(FinderView)),
    );
    await tester.pumpWidget(
      app(FinderView(controller: controller, actions: actions)),
    );
    await tester.pump();
    // Going to the device does not unfold it.
    final disclosure = find.byKey(const ValueKey('files-sidebar-expand'));
    expect(disclosure, findsOneWidget);
    expect(controller.sidebarExpanded, isEmpty);
    final folded = find.text('Documents').evaluate().length;

    await tester.tap(disclosure);
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.sidebarExpanded, {'phone'});
    expect(find.text('Documents').evaluate().length, folded + 1);

    // Clicked again where it is already shown, the device folds away.
    await tester.tap(find.text('OnePlus').first);
    await tester.pump(const Duration(milliseconds: 300));
    expect(controller.sidebarExpanded, isEmpty);
    expect(find.text('Documents').evaluate().length, folded);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  test(
    'a folder being opened keeps the last one up until it is ready',
    () async {
      final controller = controllerFor();
      addTearDown(controller.dispose);
      await _until(() => controller.entries.isNotEmpty);
      final home = controller.location!;
      final opening = controller.openEntry(controller.entries.first);
      // Still the folder before, not an empty one: nothing flashes.
      expect(controller.showingPrevious, isTrue);
      expect(controller.shownLocation, home);
      expect(controller.entries, isNotEmpty);
      await opening;
      expect(controller.showingPrevious, isFalse);
      expect(controller.shownLocation!.path, 'Documents');
    },
  );

  testWidgets('the phone starts on Browse and pushes into folders', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late FilesController controller;
    await tester.runAsync(() async {
      controller = controllerFor();
      await _until(() => controller.entries.isNotEmpty);
    });
    final actions = FilesActions(
      controller: controller,
      context: () => tester.element(find.byType(FilesPhoneView)),
    );
    await tester.pumpWidget(
      app(
        FilesPhoneView(
          controller: controller,
          actions: actions,
          startAtDevice: false,
        ),
        size: const Size(390, 800),
      ),
    );
    await tester.pump();
    expect(find.text('Browse'), findsWidgets);
    expect(find.text('This device'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Documents').first);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(controller.location!.path, 'Documents');
    expect(find.text('This folder is empty'), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('an iPhone opens its Whisper folder as "This device"', (
    tester,
  ) async {
    // Its sandbox is the one folder there is: tapped as "This device", it
    // reads as that, not as a favorite of the same name (seen on an iPad).
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late FilesController controller;
    await tester.runAsync(() async {
      controller = FilesController(
        local: LocalFsBrowser(
          files: FsHostFiles(
            resolver: FsPathResolver([
              FsRoot(
                id: 'documents',
                directory: local.path,
                kind: FsRootKind.documents,
              ),
            ]),
          ),
        ),
        peers: FilesPeers(
          connected: () => const {},
          canBrowse: (_) => false,
          describe: (_) => (name: '', platform: ''),
        ),
      );
      await _until(() => controller.entries.isNotEmpty);
    });
    final actions = FilesActions(
      controller: controller,
      context: () => tester.element(find.byType(FilesPhoneView)),
    );
    await tester.pumpWidget(
      app(
        FilesPhoneView(
          controller: controller,
          actions: actions,
          startAtDevice: false,
        ),
        size: const Size(390, 800),
      ),
    );
    await tester.pump();
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('Favorites'), findsNothing);
    expect(find.text('Whisper Folder'), findsNothing);
    await tester.runAsync(() async {
      await tester.tap(find.text('This device'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    expect(controller.location!.root, 'documents');
    expect(controller.location!.path, '');
    expect(find.text('This device'), findsWidgets);
    expect(find.text('Whisper Folder'), findsNothing);
    expect(find.text('b2.txt'), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  /// A copy into this device's home folder of [names], landed as [landed].
  FileCopyBatch copyHere(List<String> names, {Map<String, String>? landed}) {
    final placed = StreamController<PlacedTransfer>.broadcast(sync: true);
    final copies = FileCopies(
      updates: const Stream.empty(),
      placed: placed.stream,
      nowMs: () => 0,
    );
    addTearDown(copies.dispose);
    final batch = copies.start(
      upload: false,
      peerId: 'phone',
      deviceName: 'OnePlus',
      folder: 'home',
      names: names,
      signature: 'sig',
      target: const FilesLocation(FilesDevice.localId, 'home', ''),
    );
    for (final entry in (landed ?? const {}).entries) {
      copies.add(batch, entry.key);
      placed.add(
        PlacedTransfer(
          transferId: entry.key,
          path: p.join(local.path, entry.value),
        ),
      );
    }
    return batch;
  }

  Future<void> addFiles(int count) async {
    for (var i = 0; i < count; i++) {
      await File(
        p.join(local.path, 'f${i.toString().padLeft(2, '0')}.txt'),
      ).writeAsString('$i');
    }
  }

  test('showing where a copy went selects what it brought', () async {
    final controller = controllerFor();
    addTearDown(controller.dispose);
    await _until(() => controller.entries.isNotEmpty);
    await controller.openEntry(
      controller.entries.firstWhere((entry) => entry.name == 'Documents'),
    );
    final before = controller.revealed.value;

    await controller.reveal(copyHere(['b2.txt']));
    expect(controller.location!.path, '');
    expect(controller.selection, {'b2.txt'});
    expect(controller.revealed.value, before + 1);

    // "b10.txt" was taken, so the copy of "b2.txt"… landed as another name:
    // that one is picked, not the file that was there.
    await controller.reveal(copyHere(['b2.txt'], landed: {'t': 'b10.txt'}));
    expect(controller.selection, {'b10.txt'});

    // Gone from the folder since: nothing picked, nothing scrolled.
    await controller.reveal(copyHere(['gone.txt']));
    expect(controller.selection, {'b10.txt'});
    expect(controller.revealed.value, before + 2);
  });

  testWidgets('a copy shown on the desktop is scrolled into view', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late FilesController controller;
    await tester.runAsync(() async {
      await addFiles(80);
      controller = controllerFor();
      await _until(() => controller.entries.length > 80);
    });
    final actions = FilesActions(
      controller: controller,
      context: () => tester.element(find.byType(FinderView)),
    );
    await tester.pumpWidget(
      app(FinderView(controller: controller, actions: actions)),
    );
    await tester.pump();
    expect(find.text('f75.txt'), findsNothing);

    await tester.runAsync(() => controller.reveal(copyHere(['f75.txt'])));
    await tester.pumpAndSettle();
    expect(controller.selection, {'f75.txt'});
    expect(find.text('f75.txt'), findsOneWidget);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('a copy shown on the phone lights up its row a moment', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late FilesController controller;
    await tester.runAsync(() async {
      await addFiles(40);
      controller = controllerFor();
      await _until(() => controller.entries.length > 40);
    });
    final actions = FilesActions(
      controller: controller,
      context: () => tester.element(find.byType(FilesPhoneView)),
    );
    await tester.pumpWidget(
      app(
        FilesPhoneView(
          controller: controller,
          actions: actions,
          startAtDevice: true,
        ),
        size: const Size(390, 800),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('f35.txt'), findsNothing);

    await tester.runAsync(() => controller.reveal(copyHere(['f35.txt'])));
    await tester.pumpAndSettle();
    expect(find.text('f35.txt'), findsOneWidget);
    Color rowColor() {
      final box = tester.widget<AnimatedContainer>(
        find
            .ancestor(
              of: find.text('f35.txt'),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );
      return (box.decoration! as BoxDecoration).color!;
    }

    expect(rowColor().a, greaterThan(0));
    // Not a selection to act on: the phone is not selecting.
    expect(controller.selection, isEmpty);
    // The fade was set off from the reveal, on real time.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2100)),
    );
    await tester.pumpAndSettle();
    expect(rowColor().a, 0);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  test('the file manager opens from a device\'s page', () {
    final conversation = File('lib/page/conversation.dart').readAsStringSync();
    expect(conversation, contains('RemoteFilesPage(peerId: device.uid'));
    expect(conversation, contains('features: _deviceFeatures()'));
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();
    expect(deviceList, isNot(contains('RemoteFilesPage()')));
    expect(canOfferRemoteFiles(), !Platform.isIOS);
    final page = File(
      'lib/page/remote_files/remote_files_page.dart',
    ).readAsStringSync();
    expect(page, contains('constraints.maxWidth >= 700'));
    expect(page, contains('FinderView('));
    expect(page, contains('FilesPhoneView('));
  });

  test(
    'copied files reach Finder, and Finder\'s copies can be pasted',
    () async {
      final clipboard = _FakeClipboard();
      final controller = FilesController(
        local: LocalFsBrowser(files: _files(local.path)),
        systemClipboard: clipboard,
        peers: FilesPeers(
          connected: () => const {},
          canBrowse: (_) => false,
          describe: (_) => null,
        ),
      );
      addTearDown(controller.dispose);
      await _until(() => controller.entries.isNotEmpty);
      controller.select('b2.txt');
      controller.copySelection();
      await _until(() => clipboard.contents.isNotEmpty);
      expect(p.basename(clipboard.contents.single), 'b2.txt');
      // Our own copy is not "something copied elsewhere".
      expect(await controller.externalClipboardPaths(), isNull);
      clipboard.contents = ['/elsewhere/report.pdf'];
      expect(await controller.externalClipboardPaths(), [
        '/elsewhere/report.pdf',
      ]);
    },
  );

  test('copying one file, then another, pastes the second one', () async {
    final clipboard = _RespellingClipboard();
    final controller = FilesController(
      local: LocalFsBrowser(files: _files(local.path)),
      systemClipboard: clipboard,
      peers: FilesPeers(
        connected: () => const {},
        canBrowse: (_) => false,
        describe: (_) => null,
      ),
    );
    addTearDown(controller.dispose);
    await _until(() => controller.entries.isNotEmpty);
    controller.select('b2.txt');
    controller.copySelection();
    await _until(() => clipboard.contents.isNotEmpty);
    // Read back spelled differently, it is still this copy, not Finder's.
    expect(await controller.externalClipboardPaths(), isNull);
    controller.select('photo.jpg');
    controller.copySelection();
    await _until(() => p.basename(clipboard.contents.single) == 'photo.jpg');
    expect(await controller.externalClipboardPaths(), isNull);
    expect(controller.clipboard.single.path, 'photo.jpg');
  });

  group('another device\'s files on the clipboard', () {
    late Directory downloads;

    setUp(() async {
      downloads = await Directory.systemTemp.createTemp('whisper-files-dl-');
    });

    tearDown(() async {
      await downloads.delete(recursive: true);
    });

    /// The other device's transfer [id] of [name] arrives.
    Future<void> arrive(String id, String name, String content) async {
      final file = File(p.join(downloads.path, name));
      await file.writeAsString(content);
      await TransferPlacements.shared.onTransferUpdated(
        TransferSnapshot(
          transferId: id,
          messageUuid: id,
          peerUid: 'phone',
          direction: FileTransferDirection.incoming,
          state: FileTransferState.completed,
          finalPath: file.path,
          tempPath: '',
          size: content.length,
          committedBytes: content.length,
          lastError: '',
          updatedAt: 0,
        ),
      );
    }

    Future<(FilesController, _FakeClipboard)> browsePhone() async {
      final clipboard = _FakeClipboard();
      final controller = FilesController(
        local: LocalFsBrowser(files: _files(local.path)),
        systemClipboard: clipboard,
        peers: FilesPeers(
          connected: () => {'phone'},
          canBrowse: (_) => true,
          describe: (_) => (name: 'OnePlus', platform: 'android'),
        ),
      );
      addTearDown(controller.dispose);
      await _until(() => controller.entries.isNotEmpty);
      await controller.open(controller.deviceById('phone')!);
      return (controller, clipboard);
    }

    test('another device\'s files are fetched only once pasted here', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final (controller, clipboard) = await browsePhone();
      clipboard.contents = ['/elsewhere/older.pdf'];
      controller.select('photo.jpg');
      controller.copySelection();
      await _until(() => controller.clipboardOnPaste);
      // Finder pastes only files already on disk: nothing is fetched for
      // it (a drag takes them there). The older thing is gone, or a paste
      // there brought it out as a file of its own ("已粘贴 …").
      expect(controller.copies, isEmpty);
      expect(clipboard.contents, isEmpty);
      expect(controller.clipboardDragsOut, isTrue);
      // Leaving the app (for Finder, say) fetches nothing either.
      TestWidgetsFlutterBinding.instance
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed)
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      expect(controller.copies, isEmpty);

      const docs = FilesLocation(FilesDevice.localId, 'home', 'Documents');
      expect(await controller.externalClipboardPaths(), isNull);
      expect(await controller.copy(controller.clipboard, docs), 1);
      await _until(() => controller.copies.length == 1);
      await arrive(controller.copies.keys.single, 'photo.jpg', 'jpg');
      final landed = File(p.join(local.path, 'Documents', 'photo.jpg'));
      await _until(landed.existsSync);
      expect(await landed.readAsString(), 'jpg');
    });

    test('what the system file manager takes by a drag', () {
      const phone = FilesLocation('phone', 'home', '');
      const file = FilesItem(phone, 'b2.txt', isDir: false);
      const folder = FilesItem(phone, 'z folder', isDir: true);
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final takes = <TargetPlatform, (bool, bool)>{};
      for (final platform in [
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.linux,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        takes[platform] = (filesDragsOut(file), filesDragsOut(folder));
      }
      // Finder takes files and folders; Explorer files; on Linux a drag
      // stays in the window.
      expect(takes, {
        TargetPlatform.macOS: (true, true),
        TargetPlatform.windows: (true, false),
        TargetPlatform.linux: (false, false),
      });
    });

    test('a paste waiting for one copy still lands after the next', () async {
      final (controller, _) = await browsePhone();
      controller.select('b2.txt');
      controller.copySelection();
      const home = FilesLocation(FilesDevice.localId, 'home', '');
      expect(await controller.copy(controller.clipboard, home), 1);
      await _until(() => controller.copies.length == 1);
      final first = controller.copies.keys.single;

      // Copied again before the first one arrived.
      controller.select('photo.jpg');
      controller.copySelection();
      await _until(() => controller.clipboardOnPaste);
      await arrive(first, 'b2.txt', 'two');
      final pasted = File(p.join(local.path, 'b2 2.txt'));
      await _until(pasted.existsSync);
      expect(await pasted.readAsString(), 'two');
    });

    test(
      'a drag carries the items for the window and files for apps',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final (controller, _) = await browsePhone();
        const home = FilesLocation(FilesDevice.localId, 'home', '');
        const phone = FilesLocation('phone', 'home', '');
        for (final item in [
          const FilesItem(home, 'b2.txt', isDir: false),
          const FilesItem(phone, 'z folder', isDir: true),
        ]) {
          final read = filesItemFromLocalData(
            (await filesDragItem(controller, item)).localData,
          )!;
          expect(read.location, item.location);
          expect((read.name, read.isDir), (item.name, item.isDir));
        }
        Future<List<Object>> kinds(FilesItem item) async => [
          for (final data in (await filesDragItem(controller, item)).data)
            for (final representation in (await data).representations)
              representation.runtimeType,
        ];
        // This device's file as it is; another device's file once fetched;
        // another device's folder as a folder Finder fills from here.
        expect(await kinds(const FilesItem(home, 'b2.txt', isDir: false)), [
          raw.DataRepresentationSimple,
        ]);
        expect(await kinds(const FilesItem(phone, 'b2.txt', isDir: false)), [
          raw.DataRepresentationVirtualFile,
        ]);
        final folder = [
          for (final data in (await filesDragItem(
            controller,
            const FilesItem(phone, 'z folder', isDir: true),
          )).data)
            ...(await data).representations,
        ];
        expect(folder.single, isA<raw.DataRepresentationVirtualFile>());
        expect(
          (folder.single as raw.DataRepresentationVirtualFile).format,
          'public.folder',
        );
        expect(filesItemFromLocalData({'path': '/elsewhere'}), isNull);
      },
    );

    test('dropped in another app, a file is fetched and handed over', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final asked = <String>[];
      host.sendFile = (peerId, path, id) async {
        asked.add(id);
        return true;
      };
      final (controller, _) = await browsePhone();
      final dragItem = await filesDragItem(
        controller,
        const FilesItem(
          FilesLocation('phone', 'home', ''),
          'b2.txt',
          isDir: false,
        ),
      );
      final virtualFile =
          (await dragItem.data.single).representations.single
              as raw.DataRepresentationVirtualFile;
      final app = _AppFile();
      final progress = _AppProgress();
      int? size;
      // What Finder or Explorer does once the file is dropped.
      virtualFile.virtualFileProvider(({required int fileSize}) {
        size = fileSize;
        return app;
      }, progress);
      await _until(() => asked.isNotEmpty);
      final content = 'two' * 1000;
      await arrive(asked.single, 'b2.txt', content);
      await _until(() => app.closed);
      expect(utf8.decode(app.bytes.takeBytes()), content);
      expect(size, content.length);
      expect(app.error, isNull);
      expect(progress.fractions.last, 1);
      // The copy made for it is gone again.
      final outs = Directory(
        p.join(Directory.systemTemp.path, 'whisper_files_clipboard'),
      ).listSync().where((entry) => p.basename(entry.path).startsWith('out-'));
      for (final out in outs) {
        expect(
          Directory(
            out.path,
          ).listSync().any((e) => p.basename(e.path) == 'b2.txt'),
          isFalse,
        );
      }
    });

    test('an app that stops waiting cancels the fetch', () async {
      final (controller, _) = await browsePhone();
      final out = controller.fetchOut(
        const FilesItem(
          FilesLocation('phone', 'home', ''),
          'b2.txt',
          isDir: false,
        ),
      );
      await _until(() => out.transferId != null);
      out.cancel();
      await expectLater(
        out.path,
        throwsA(
          isA<RemoteFsException>().having(
            (e) => e.reason,
            'reason',
            'canceled',
          ),
        ),
      );
      await out.dispose();
    });

    test('on Windows Explorer fetches a pasted file itself', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final (controller, clipboard) = await browsePhone();
      controller.select('b2.txt');
      controller.copySelection();
      await _until(() => clipboard.fetched.isNotEmpty);
      // On the clipboard at once, nothing fetched ahead.
      expect(clipboard.fetched.single.path, 'b2.txt');
      expect(controller.clipboardReady, isTrue);
      expect(controller.copies, isEmpty);

      // Pasted here, it is fetched straight into the folder.
      const docs = FilesLocation(FilesDevice.localId, 'home', 'Documents');
      expect(await controller.copy(controller.clipboard, docs), 1);
      await _until(() => controller.copies.length == 1);
      await arrive(controller.copies.keys.single, 'b2.txt', 'two');
      final landed = File(p.join(local.path, 'Documents', 'b2.txt'));
      await _until(landed.existsSync);

      // A folder is not a file Explorer can be handed: it comes over once
      // pasted here.
      clipboard.fetched = const [];
      controller.select('z folder');
      controller.copySelection();
      await _until(() => controller.clipboardOnPaste);
      expect(clipboard.fetched, isEmpty);
      expect(controller.copies, hasLength(1));
    });

    testWidgets('the drag picture keeps its own size inside a long row', (
      tester,
    ) async {
      final snapshotter = GlobalKey<WidgetSnapshotterState>();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 900,
              height: 28,
              child: WidgetSnapshotter(
                key: snapshotter,
                child: const ColoredBox(color: Color(0xFF888888)),
              ),
            ),
          ),
        ),
      );
      // The picture is built into the tree to be laid out and drawn; its
      // size there is the size of the picture.
      const face = ValueKey('drag-face');
      unawaited(
        snapshotter.currentState!.getSnapshot(
          const Offset(10, 10),
          Object(),
          () => filesDragPicture(
            const SizedBox(
              key: face,
              width: 84,
              height: 84,
              child: ColoredBox(color: Color(0xFF0A84FF)),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.getSize(find.byKey(face)), const Size(84, 84));
    });

    testWidgets('⌘C, a place in the sidebar, ⌘V: the paste starts at once', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1100, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // Real time passes here, enough for the system drag and drop to set
      // itself up: it finds no native side and does nothing.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.irondash.engine_context'),
        (call) async => 1,
      );
      final native = superNativeExtensionsContext as MockMessageChannelContext;
      for (final channel in ['DragManager', 'DropManager']) {
        native.registerMockMethodCallHandler(channel, (call) async => null);
      }
      late FilesController controller;
      await tester.runAsync(() async {
        (controller, _) = await browsePhone();
      });
      final actions = FilesActions(
        controller: controller,
        context: () => tester.element(find.byType(FinderView)),
      );
      await tester.pumpWidget(
        app(FinderView(controller: controller, actions: actions)),
      );
      await tester.pump();
      // What the keys start runs in the test's zone: frames and real time
      // both have to pass.
      Future<void> until(bool Function() done) async {
        for (var i = 0; i < 200 && !done(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(done(), isTrue);
      }

      final primary = Platform.isMacOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      Future<void> press(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(primary);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(primary);
        await tester.pump();
      }

      // A file no other test here copies (the same paste twice within
      // seconds is one copy).
      await tester.tap(find.text('b10.txt'));
      await tester.pump();
      await press(LogicalKeyboardKey.keyC);
      await until(() => controller.clipboardOnPaste);
      expect(controller.copies, isEmpty);

      // This Mac's Documents, picked in the sidebar.
      await tester.tap(find.text('Documents').first);
      await until(() => controller.location?.deviceId == FilesDevice.localId);
      await press(LogicalKeyboardKey.keyV);
      await until(() => controller.copies.length == 1);
      final fetching = controller.copies.keys.single;
      FileCopyBatch? pasted() => controller.copyList.batches
          .where((batch) => batch.transfers.containsKey(fetching))
          .firstOrNull;
      await until(() => pasted() != null);
      expect(pasted()!.finished, isFalse);

      await tester.runAsync(() => arrive(fetching, 'b10.txt', 'ten'));
      final landed = File(p.join(local.path, 'Documents', 'b10.txt'));
      await until(landed.existsSync);
      await until(() => pasted()!.finished);
      await tester.pumpWidget(const SizedBox());
      // The status bar's "copied" note goes after a while.
      await tester.pump(const Duration(seconds: 9));
    });
  });
}
