// The two small sheets of the desktop shell: 输入地址连接 and 共享「…」.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:whisper/l10n/app_localizations_zh.dart';
import 'package:whisper/new_ui/shell/shell_link_create.dart';
import 'package:whisper/new_ui/shell/shell_manual_connect.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/page/pairing_qr.dart';
import 'package:whisper/share_links/share_link_store.dart';
import 'package:whisper/share_links/share_server.dart';

import 'support/golden_support.dart';

class _MemoryPreferences implements ShareLinkPreferences {
  final values = <String, Object>{};

  @override
  Future<bool?> getBool(String key) async => values[key] as bool?;

  @override
  Future<int?> getInt(String key) async => values[key] as int?;

  @override
  Future<String?> getString(String key) async => values[key] as String?;

  @override
  Future<void> setBool(String key, bool value) async => values[key] = value;

  @override
  Future<void> setInt(String key, int value) async => values[key] = value;

  @override
  Future<void> setString(String key, String value) async => values[key] = value;
}

/// Pretends to listen, so these tests need no sockets.
class _FakeServer extends ShareServer {
  _FakeServer(ShareServerSource source) : super(source: source);

  int? _port;

  @override
  bool get isRunning => _port != null;

  @override
  int? get port => _port;

  @override
  Future<int> start(List<int> ports) async => _port = ports.first;

  @override
  Future<void> stop() async => _port = null;
}

/// Opens [sheet] from a button and reports what it closes with.
Future<void> _open<T>(
  WidgetTester tester,
  WidgetBuilder sheet,
  void Function(T?) closed,
) async {
  tester.view.physicalSize = const Size(1000, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    goldenApp(
      Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async =>
                closed(await showShellSheet<T>(context, builder: sheet)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  final l10n = AppLocalizationsZh();

  group('地址和端口', () {
    test('is one line, and the port can be left out', () {
      expect(splitManualAddress('192.168.1.8').host, '192.168.1.8');
      expect(splitManualAddress('192.168.1.8').port, isNull);
      expect(splitManualAddress(' 192.168.1.8:10003 ').port, 10003);
      expect(splitManualAddress('mac.local:10003').host, 'mac.local');
      expect(splitManualAddress('[fe80::1]:10003').host, 'fe80::1');
      expect(splitManualAddress('[fe80::1]:10003').port, 10003);
      expect(splitManualAddress('fe80::1').host, 'fe80::1');
    });

    test('a port that is not one is told apart from none', () {
      expect(splitManualAddress('192.168.1.8:').portIsBad, isTrue);
      expect(splitManualAddress('192.168.1.8:abc').portIsBad, isTrue);
      expect(splitManualAddress('192.168.1.8:70000').portIsBad, isTrue);
      expect(splitManualAddress('192.168.1.8').portIsBad, isFalse);
    });
  });

  group('输入地址连接', () {
    testWidgets('starts on this network and connects to what was typed', (
      tester,
    ) async {
      PairingQrResult? result;
      await _open<PairingQrResult>(
        tester,
        (_) => const ShellManualConnect(localHost: '192.168.31.8'),
        (value) => result = value,
      );
      expect(find.text(l10n.shellManualConnectTitle), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '192.168.31.',
      );
      await tester.enterText(find.byType(TextField), '192.168.31.20');
      await tester.tap(find.text(l10n.shellConnect));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(result!.invite, isNull);
      expect(result!.endpoint.host, '192.168.31.20');
      expect(result!.endpoint.port, 10002);
    });

    testWidgets('says what is wrong and stays open', (tester) async {
      var closed = false;
      await _open<PairingQrResult>(
        tester,
        (_) => const ShellManualConnect(localHost: '192.168.31.8'),
        (_) => closed = true,
      );
      await tester.enterText(find.byType(TextField), '192.168.31.20:99999');
      await tester.tap(find.text(l10n.shellConnect));
      await tester.pump();
      expect(find.text(l10n.manualConnectPortInvalid), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'not an address');
      await tester.pump();
      expect(find.text(l10n.manualConnectPortInvalid), findsNothing);
      await tester.tap(find.text(l10n.shellConnect));
      await tester.pump();
      expect(find.text(l10n.manualConnectAddressInvalid), findsOneWidget);
      expect(closed, isFalse);
    });
  });

  group('共享「…」', () {
    late Directory temp;
    late String photo;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('shell_link_');
      photo = p.join(temp.path, 'IMG_0042.jpg');
      await File(photo).writeAsBytes(List.filled(2048, 1));
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    Future<ShareLinkStore> ready(WidgetTester tester) async =>
        (await tester.runAsync(() async {
          final store = ShareLinkStore(
            preferences: _MemoryPreferences(),
            server: _FakeServer.new,
            addresses: () async => ['192.168.31.230'],
            deviceName: () async => 'MacBook',
          );
          await store.initialize();
          return store;
        }))!;

    /// Real file work: on a busy machine it takes as long as it takes.
    Future<void> settleCreate(
      WidgetTester tester, {
      bool Function()? until,
    }) async {
      for (var i = 0; i < 200 && !(until?.call() ?? false); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('makes the link with what was typed', (tester) async {
      final store = await ready(tester);
      ShareLink? link;
      await _open<ShareLink>(
        tester,
        (_) =>
            ShellLinkCreate(store: store, paths: [photo], name: 'IMG_0042.jpg'),
        (value) => link = value,
      );
      expect(
        find.text(l10n.shellLinkCreateTitle('IMG_0042.jpg')),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField).first, 'trip-2026');
      await tester.enterText(find.byType(TextField).last, 'pw');
      await tester.tap(find.text(l10n.shareLinkCreate));
      await settleCreate(tester, until: () => link != null);
      expect(link!.route, 'trip-2026');
      expect(link!.items.single.path, photo);
      expect(link!.hasPassword, isTrue);
      await tester.runAsync(store.shutdown);
    });

    testWidgets('left empty, it uses the route it suggested', (tester) async {
      final store = await ready(tester);
      ShareLink? link;
      await _open<ShareLink>(
        tester,
        (_) => ShellLinkCreate(store: store, paths: [photo], name: 'a'),
        (value) => link = value,
      );
      final hint = tester
          .widget<TextField>(find.byType(TextField).first)
          .decoration!
          .hintText!;
      await tester.tap(find.text(l10n.shareLinkCreate));
      await settleCreate(tester, until: () => link != null);
      expect(link!.route, hint);
      expect(link!.hasPassword, isFalse);
      await tester.runAsync(store.shutdown);
    });

    testWidgets('a route another link has is said while typing', (
      tester,
    ) async {
      final store = await ready(tester);
      await tester.runAsync(() => store.create(paths: [photo], route: 'taken'));
      var closed = false;
      await _open<ShareLink>(
        tester,
        (_) => ShellLinkCreate(store: store, paths: [photo], name: 'a'),
        (_) => closed = true,
      );
      await tester.enterText(find.byType(TextField).first, 'taken');
      await tester.pump();
      expect(find.text(l10n.shareLinkRouteTaken), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'free-route');
      await tester.pump();
      expect(find.text(l10n.shareLinkRouteTaken), findsNothing);
      expect(closed, isFalse);
      await tester.runAsync(store.shutdown);
    });

    testWidgets('too short waits until 创建链接', (tester) async {
      final store = await ready(tester);
      var closed = false;
      await _open<ShareLink>(
        tester,
        (_) => ShellLinkCreate(store: store, paths: [photo], name: 'a'),
        (_) => closed = true,
      );
      await tester.enterText(find.byType(TextField).first, 'a');
      await tester.pump();
      expect(find.text(l10n.shareLinkRouteInvalid), findsNothing);
      await tester.tap(find.text(l10n.shareLinkCreate));
      await tester.pump();
      expect(find.text(l10n.shareLinkRouteInvalid), findsOneWidget);
      expect(closed, isFalse);
      await tester.runAsync(store.shutdown);
    });
  });
}
