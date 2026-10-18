import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/page/window_stream/flow_offer_banner.dart';
import 'package:whisper/page/remote_files/files_model.dart';
import 'package:whisper/page/remote_files/files_phone.dart';
import 'package:whisper/page/remote_files/remote_files_page.dart';
import 'package:whisper/page/window_stream/flow_space_theme.dart';
import 'package:whisper/remote_files/fs_browser.dart';
import 'package:whisper/remote_files/fs_copies.dart';
import 'package:whisper/remote_files/fs_host_files.dart';
import 'package:whisper/remote_files/fs_paths.dart';
import 'package:whisper/theme/app_theme.dart';
import 'package:whisper/widget/island/island_activity.dart';
import 'package:whisper/widget/island/island_center.dart';
import 'package:whisper/widget/island/island_host.dart';
import 'package:whisper/widget/island/sources/audio_source.dart';
import 'package:whisper/widget/island/sources/copy_source.dart';
import 'package:whisper/widget/island/sources/streamed_source.dart';
import 'package:whisper/widget/island/sources/transfer_source.dart';
import 'package:whisper/window_stream/core/window_stream_models.dart';
import 'package:whisper/window_stream/remote/remote_peer_source.dart';
import 'package:whisper/window_stream/remote/window_stream_control.dart';

/// Renders the island's states to PNG files for a look by eye:
///   ISLAND_PREVIEW_DIR=/some/dir flutter test test/island_preview_test.dart
/// Skipped otherwise.
void main() {
  final out = Platform.environment['ISLAND_PREVIEW_DIR'];

  testWidgets('island previews', skip: out == null, (tester) async {
    await tester.runAsync(_loadFonts);
    final boundary = GlobalKey();
    final source = IslandListSource();
    final center = IslandCenter(sources: [source]);

    // A copy under way, with a speed.
    var nowMs = 0;
    final updates = StreamController<TransferSnapshot>.broadcast(sync: true);
    final copies = FileCopies(updates: updates.stream, nowMs: () => nowMs);
    final batch = copies.start(
      upload: true,
      peerId: 'p',
      deviceName: '一加 8',
      folder: '下载',
      names: ['ChatGPT.dmg'],
      signature: 's',
    );
    copies.add(batch, 't1');
    copies.started(batch);
    const size = 654700000;
    void progress(double fraction) => updates.add(
      TransferSnapshot(
        transferId: 't1',
        messageUuid: 't1',
        peerUid: 'p',
        direction: FileTransferDirection.outgoing,
        state: FileTransferState.transferring,
        finalPath: '/x/ChatGPT.dmg',
        tempPath: '',
        size: size,
        committedBytes: (size * fraction).round(),
        lastError: '',
        updatedAt: nowMs,
      ),
    );
    progress(0.41);
    copies.tick();
    nowMs = 1000;
    progress(0.45);
    copies.tick();
    nowMs = 2000;
    progress(0.48);
    copies.tick();

    IslandActivity copy() => IslandActivity(
      id: CopyIslandSource.idOf(batch),
      kind: IslandKind.copy,
      status: islandStatusOfCopy(batch.phase),
      since: batch.started,
      arrival: IslandArrival.quiet,
      presenter: CopyPresenter(batch: batch, copies: copies),
    );

    IslandActivity audio({IslandAudioState state = IslandAudioState.playing}) =>
        IslandActivity(
          id: 'audio',
          kind: IslandKind.audio,
          status: state == IslandAudioState.paused
              ? IslandStatus.paused
              : IslandStatus.live,
          since: DateTime(2026, 10, 17, 11),
          arrival: IslandArrival.quiet,
          presenter: AudioPresenter(
            id: 'audio',
            device: 'MacBook Pro',
            state: state,
            actions: IslandAudioActions(
              pause: state == IslandAudioState.playing ? () async {} : null,
              resume: state == IslandAudioState.paused ? () async {} : null,
              disconnect: () async {},
            ),
          ),
        );

    IslandActivity streamed() => IslandActivity(
      id: 'streamed',
      kind: IslandKind.streamed,
      status: IslandStatus.live,
      since: DateTime(2026, 10, 17, 11),
      arrival: IslandArrival.quiet,
      presenter: StreamedPresenter(
        id: 'streamed',
        windows: 2,
        viewer: 'MacBook Pro',
        stopping: false,
        ended: false,
        stop: () async {},
      ),
    );

    IslandActivity transfer({
      IslandStatus status = IslandStatus.live,
      String? name = 'IMG_2041.HEIC',
      int count = 1,
    }) => IslandActivity(
      id: 'transfer',
      kind: IslandKind.transfer,
      status: status,
      since: DateTime(2026, 10, 17, 11, 30),
      arrival: IslandArrival.quiet,
      presenter: TransferPresenter(
        id: 'transfer',
        stats: TransferStats(
          status: status,
          count: count,
          completed: status == IslandStatus.done ? count : 0,
          outgoing: 0,
          incoming: count,
          totalBytes: 48200000,
          doneBytes: status == IslandStatus.done ? 48200000 : 31500000,
          speed: status == IslandStatus.live ? 11800000 : 0,
          remaining: status == IslandStatus.live
              ? const Duration(seconds: 2)
              : null,
          starting: false,
          name: name,
          device: 'MacBook Pro',
          canRetry: false,
        ),
        stop: () async {},
      ),
    );

    final viewer = WindowStreamViewer.shared;
    viewer.peerAvailable(
      peerId: 'mac',
      name: 'MacBook Pro',
      platform: WindowStreamPlatform.macos,
      host: '127.0.0.1',
      port: 1,
    );
    addTearDown(() => viewer.peerGone('mac'));
    final offer = WindowOffer(
      source: viewer.sourceFor('mac')!,
      window: const RemoteWindowInfo(
        id: 7,
        appId: 'com.apple.Notes',
        appName: '备忘录',
        title: '周末采购清单',
        width: 900,
        height: 700,
      ),
    );
    IslandActivity offered() => IslandActivity(
      id: 'offer',
      kind: IslandKind.offer,
      status: IslandStatus.live,
      since: DateTime(2026, 10, 17, 12),
      arrival: IslandArrival.quiet,
      presenter: OfferPresenter(
        id: 'offer',
        offer: offer,
        onView: () {},
        onIgnore: () {},
      ),
    );

    tester.view.physicalSize = const Size(1236, 2676);
    tester.view.devicePixelRatio = 3;
    tester.view.padding = const FakeViewPadding(top: 84, bottom: 48);
    addTearDown(tester.view.reset);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    Future<void> scene(
      String name,
      List<IslandActivity> activities, {
      bool open = false,
      String? feature,
      bool dark = false,
      double textScale = 1,
      Locale locale = const Locale('zh'),
      int? frames,
      Widget page = const _Page(),
    }) async {
      center.collapse();
      source.activities = const [];
      await _settle(tester);
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(
            tester.view,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: AppTheme.lightTheme,
            darkTheme: AppTheme.darkTheme,
            themeMode: dark ? ThemeMode.dark : ThemeMode.light,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: locale,
            navigatorKey: navigatorKey,
            useInheritedMediaQuery: true,
            builder: (context, child) => RepaintBoundary(
              key: boundary,
              child: IslandHost(
                navigatorKey: navigatorKey,
                center: center,
                child: child!,
              ),
            ),
            home: page,
          ),
        ),
      );
      source.activities = activities;
      await _settle(tester);
      if (open) {
        center.tap();
        if (feature != null) {
          center.feature(feature);
        }
        await _settle(tester, frames ?? 30);
      }
      await _capture(tester, boundary, '$out/$name.png');
    }

    await scene('01_compact_copy', [copy()]);
    await scene('02_compact_split', [copy(), audio()]);
    await scene('03_card_copy', [copy()], open: true);
    await scene('04_card_three', [streamed(), copy(), audio()], open: true);
    await scene('05_card_offer', [offered(), transfer()], open: true);
    await scene(
      '06_card_audio_dark',
      [audio(), transfer(name: null, count: 3)],
      open: true,
      feature: 'audio',
      dark: true,
    );
    await scene('07_compact_done_dark', [
      transfer(status: IslandStatus.done),
    ], dark: true);
    await scene(
      '08_card_large_text',
      [transfer(), copy()],
      open: true,
      feature: 'transfer',
      textScale: 1.5,
    );
    await scene('09_compact_streamed', [streamed(), audio()]);
    await scene(
      '10_card_three_en',
      [streamed(), copy(), audio(state: IslandAudioState.paused)],
      open: true,
      locale: const Locale('en'),
    );
    await scene('11_compact_offer', [offered()]);
    // Pages make room for the small island (the band under the status bar).
    await scene('13_band_device_list_dark', [copy(), audio()], dark: true);
    await scene('14_band_conversation', [
      transfer(),
    ], page: const _Conversation());
    await scene(
      '15_band_conversation_dark',
      [transfer()],
      page: const _Conversation(),
      dark: true,
    );
    await scene('16_band_flow', [streamed()], page: const _FlowLike());
    await scene(
      '17_band_flow_dark',
      [streamed()],
      page: const _FlowLike(),
      dark: true,
    );
    // The phone's real file manager page, inside its SafeArea.
    SharedPreferences.setMockInitialValues({});
    late Directory folder;
    late FilesController files;
    await tester.runAsync(() async {
      folder = await Directory.systemTemp.createTemp('island-preview-');
      for (final name in ['Documents', 'Download', 'Pictures']) {
        await Directory('${folder.path}/$name').create();
      }
      await File('${folder.path}/notes.txt').writeAsString('x');
      files = FilesController(
        copyList: copies,
        local: LocalFsBrowser(
          files: FsHostFiles(
            resolver: FsPathResolver([
              FsRoot(id: 'home', directory: folder.path),
            ]),
          ),
        ),
        peers: FilesPeers(
          connected: () => {'mac'},
          canBrowse: (_) => true,
          describe: (_) => (name: 'MacBook Pro', platform: 'macos'),
        ),
      );
      for (var i = 0; i < 100 && files.entries.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    final filesKey = GlobalKey();
    // As RemoteFilesPage lays it out: its canvas behind the status bar.
    final filePage = Builder(
      builder: (context) => Scaffold(
        backgroundColor: FlowSpaceColors.of(context).canvas,
        body: SafeArea(
          bottom: false,
          child: FilesPhoneView(
            key: filesKey,
            controller: files,
            actions: FilesActions(
              controller: files,
              context: () => filesKey.currentContext!,
            ),
            startAtDevice: false,
          ),
        ),
      ),
    );
    await scene('18_band_files_phone', [copy()], page: filePage);
    await scene(
      '19_band_files_phone_dark',
      [copy(), audio()],
      page: filePage,
      dark: true,
    );
    await scene('20_files_phone_no_island', const [], page: filePage);
    // Caught on the way: the card opening, content coming out of a blur.
    await scene('12_opening_midway', [copy(), audio()], open: true, frames: 3);
    center.collapse();
    source.activities = const [];
    await _settle(tester, 40);
    await tester.pumpWidget(const SizedBox());
    files.dispose();
    await tester.runAsync(() => folder.delete(recursive: true));
    center.dispose();
    copies.dispose();
    await updates.close();
    await tester.pump(const Duration(seconds: 10));
  });
}

class _Page extends StatelessWidget {
  const _Page();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        leading: const Icon(Icons.qr_code_scanner_rounded),
        title: const Column(
          children: [
            Text('OnePlus 8'),
            Text(
              '192.168.31.8:10002',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: const [
          Padding(padding: EdgeInsets.all(12), child: Icon(Icons.settings)),
        ],
      ),
      body: ListView(
        children: [
          for (final name in ['MacBook Pro', 'Windows 台式机', 'Ubuntu 笔记本'])
            ListTile(
              leading: const Icon(Icons.computer),
              title: Text(name),
              subtitle: const Text('已连接'),
            ),
        ],
      ),
    );
  }
}

Future<void> _settle(WidgetTester tester, [int steps = 24]) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String path) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await File(path).writeAsBytes(bytes!.buffer.asUint8List());
  });
}

Future<void> _loadFonts() async {
  Future<ByteData> read(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  const text = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';
  for (final family in [
    'Roboto',
    'CupertinoSystemText',
    'CupertinoSystemDisplay',
  ]) {
    final loader = FontLoader(family)..addFont(read(text));
    await loader.load();
  }
  final home = Platform.environment['HOME'];
  final icons = FontLoader('packages/cupertino_icons/CupertinoIcons')
    ..addFont(
      read(
        '$home/.pub-cache/hosted/pub.dev/cupertino_icons-1.0.9/assets/'
        'CupertinoIcons.ttf',
      ),
    );
  await icons.load();
  final material = FontLoader('MaterialIcons')
    ..addFont(
      read(
        '${_flutterRoot()}/bin/cache/artifacts/material_fonts/'
        'MaterialIcons-Regular.otf',
      ),
    );
  await material.load();
}

String _flutterRoot() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    return root;
  }
  // flutter test runs from the Flutter checkout's dart; walk up from it.
  var dir = File(Platform.resolvedExecutable).parent;
  while (dir.path != dir.parent.path) {
    if (File('${dir.path}/bin/flutter').existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  return '';
}

/// Laid out like the conversation page: back, name, actions, messages and
/// the composer at the bottom.
class _Conversation extends StatelessWidget {
  const _Conversation();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        leading: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
        title: const Text('MacBook Pro'),
        actions: const [
          Icon(Icons.folder_outlined),
          SizedBox(width: 16),
          Icon(Icons.speaker_outlined),
          SizedBox(width: 16),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final (mine, text) in [
                  (false, '把照片发我一下'),
                  (true, '好，马上'),
                  (true, 'IMG_2041.HEIC'),
                ])
                  Align(
                    alignment: mine
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: mine
                            ? scheme.primaryContainer
                            : scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(text),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              margin: const EdgeInsets.all(12),
              height: 44,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(22),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Laid out like the Flow page: a plain canvas in a SafeArea, a title row,
/// the device shelf and the window stack.
class _FlowLike extends StatelessWidget {
  const _FlowLike();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                  const SizedBox(width: 12),
                  Text('流转', style: Theme.of(context).textTheme.headlineSmall),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  for (final name in ['MacBook Pro', 'Windows'])
                    Container(
                      margin: const EdgeInsets.only(right: 12),
                      width: 120,
                      height: 90,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      alignment: Alignment.bottomCenter,
                      padding: const EdgeInsets.all(8),
                      child: Text(name),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
