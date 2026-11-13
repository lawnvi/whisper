import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' show Ed25519, SimpleKeyPair;

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/app_update.dart';
import 'package:whisper/helper/update_signature.dart';

late SimpleKeyPair _releaseKey;
late List<String> _trustedKeys;

Future<String> _sign(
  String tag,
  String name,
  String sha256Hex, {
  SimpleKeyPair? key,
}) async {
  final signature = await Ed25519().sign(
    utf8.encode(
      updateSignatureStatement(tag: tag, assetName: name, sha256Hex: sha256Hex),
    ),
    keyPair: key ?? _releaseKey,
  );
  return base64.encode(signature.bytes);
}

const _digest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Map<String, Object?> _asset(String name) => <String, Object?>{
  'name': name,
  'size': 1024,
  'digest': 'sha256:$_digest',
  'browser_download_url':
      'https://github.com/lawnvi/whisper/releases/download/dev-v0.0.48/$name',
};

Map<String, Object?> _release({
  required String tag,
  bool draft = false,
  List<Map<String, Object?>>? assets,
}) {
  return <String, Object?>{
    'tag_name': tag,
    'draft': draft,
    'html_url': 'https://github.com/lawnvi/whisper/releases/tag/$tag',
    'published_at': '2026-08-15T00:00:00Z',
    'body': 'Release notes',
    'assets': assets ?? <Map<String, Object?>>[],
  };
}

void main() {
  setUpAll(() async {
    _releaseKey = await Ed25519().newKeyPair();
    final publicKey = await _releaseKey.extractPublicKey();
    _trustedKeys = [base64.encode(publicKey.bytes)];
  });

  group('installing a downloaded update', () {
    late Directory directory;
    late AppUpdateDownload download;

    AppUpdateDownload withSignature(String? signature) => AppUpdateDownload(
      file: download.file,
      release: download.release,
      signature: signature,
    );

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('whisper-update-test-');
      final file = File('${directory.path}/package with spaces.deb');
      await file.writeAsString('test package');
      final digest = (await sha256.bind(file.openRead()).first).toString();
      final asset = AppUpdateAsset(
        name: 'package with spaces.deb',
        downloadUrl: Uri.parse('https://github.com/lawnvi/whisper/update.deb'),
        size: await file.length(),
        sha256: digest,
      );
      download = AppUpdateDownload(
        file: file,
        release: AppUpdateRelease(
          version: '0.0.52',
          tagName: 'dev-v0.0.52',
          channel: AppUpdateChannel.preview,
          releaseUrl: Uri.parse('https://github.com/lawnvi/whisper/releases'),
          notes: '',
          publishedAt: null,
          asset: asset,
        ),
        signature: await _sign('dev-v0.0.52', asset.name, digest),
      );
    });

    // Before signatures, a package matching the digest of whichever listing
    // answered first (GitHub or the mirror) was installed, as root or SYSTEM.
    test('installs nothing that the release key did not sign for this '
        'release, this package and these bytes', () async {
      final otherKey = await Ed25519().newKeyPair();
      final asset = download.release.asset!;
      final digest = asset.sha256!;
      final cases = <String, String?>{
        'no signature': null,
        'not base64': 'not a signature',
        'another key': await _sign(
          'dev-v0.0.52',
          asset.name,
          digest,
          key: otherKey,
        ),
        'an older release': await _sign('dev-v0.0.51', asset.name, digest),
        'another package': await _sign('dev-v0.0.52', 'other.deb', digest),
        'other bytes': await _sign('dev-v0.0.52', asset.name, _digest),
      };
      for (final MapEntry(key: reason, value: signature) in cases.entries) {
        for (final platform in [
          AppUpdatePlatform.windows,
          AppUpdatePlatform.linux,
        ]) {
          final service = AppUpdateService(
            platform: platform,
            signingKeys: _trustedKeys,
            installerStarter: (_, _) async => fail('ran: $reason'),
            processRunner: (_, _) async => fail('ran: $reason'),
          );
          await expectLater(
            service.openInstaller(withSignature(signature)),
            throwsA(isA<AppUpdateException>()),
            reason: reason,
          );
        }
      }
      await expectLater(
        AppUpdateService(signingKeys: const []).openInstaller(download),
        throwsA(isA<AppUpdateException>()),
      );
    });

    tearDown(() => directory.delete(recursive: true));

    test('waits for apt and passes the installer as one argument', () async {
      var invoked = false;
      final service = AppUpdateService(
        platform: AppUpdatePlatform.linux,
        signingKeys: _trustedKeys,
        processRunner: (executable, arguments) async {
          invoked = true;
          expect(executable, '/usr/bin/pkexec');
          // Root installs its own copy, checked again: the download can
          // be swapped while the password is asked for.
          expect(arguments, [
            '/bin/sh',
            '-c',
            linuxDebInstallScript,
            'sh',
            download.file.absolute.path,
            download.release.asset!.sha256,
          ]);
          return ProcessResult(1, 0, 'installed', '');
        },
      );
      expect(
        await service.openInstaller(download),
        AppUpdateInstallDisposition.installed,
      );
      expect(invoked, isTrue);
      expect(await download.file.exists(), isTrue);
    });

    // Windows used to open the installer for the user to click through.
    test('on Windows the installer is started to update by itself, '
        'and only the package that was checked', () async {
      final started = <(String, List<String>)>[];
      final service = AppUpdateService(
        platform: AppUpdatePlatform.windows,
        signingKeys: _trustedKeys,
        installerStarter: (executable, arguments) async =>
            started.add((executable, arguments)),
      );
      expect(
        await service.openInstaller(download),
        AppUpdateInstallDisposition.exitApplication,
      );
      expect(started.single.$1, download.file.path);
      expect(started.single.$2, ['/UPDATE']);

      await download.file.writeAsString('something else');
      await expectLater(
        service.openInstaller(download),
        throwsA(isA<AppUpdateException>()),
      );
      expect(started, hasLength(1));
    });

    test(
      'does not report success when authorization or installation fails',
      () async {
        for (final exitCode in [126, 127, 100]) {
          final service = AppUpdateService(
            platform: AppUpdatePlatform.linux,
            signingKeys: _trustedKeys,
            processRunner: (_, _) async =>
                ProcessResult(1, exitCode, '', 'failed'),
          );
          await expectLater(
            service.openInstaller(download),
            throwsA(isA<AppUpdateException>()),
          );
          expect(await download.file.exists(), isTrue);
          expect(
            await File('${directory.path}/install.log').readAsString(),
            contains('exitCode=$exitCode'),
          );
        }
      },
    );

    test(
      'rejects a modified package before invoking privileged installation',
      () async {
        await download.file.writeAsString('changed package');
        final service = AppUpdateService(
          platform: AppUpdatePlatform.linux,
          signingKeys: _trustedKeys,
          processRunner: (_, _) async => throw StateError('must not execute'),
        );
        await expectLater(
          service.openInstaller(download),
          throwsA(isA<AppUpdateException>()),
        );
      },
    );
  });

  test('stable channel ignores preview releases', () {
    final result = parseGitHubReleases(
      jsonEncode(<Map<String, Object?>>[
        _release(tag: 'dev-v0.0.49'),
        _release(
          tag: 'release-v0.0.48',
          assets: <Map<String, Object?>>[
            _asset('whisper-0.0.48-windows-x86_64.exe'),
          ],
        ),
      ]),
      currentVersion: '0.0.47',
      channel: AppUpdateChannel.stable,
      platform: AppUpdatePlatform.windows,
      architecture: 'windows_x64',
    );

    expect(result.release?.tagName, 'release-v0.0.48');
    expect(result.release?.asset?.name, 'whisper-0.0.48-windows-x86_64.exe');
  });

  test('Android selects matching ABI then universal fallback', () {
    final assets = <Map<String, Object?>>[
      _asset('whisper-0.0.48-android-universal.apk'),
      _asset('whisper-0.0.48-android-arm64-v8a.apk'),
      _asset('whisper-0.0.48-android-x86_64.apk'),
    ];

    expect(
      selectUpdateAsset(
        assets,
        platform: AppUpdatePlatform.android,
        architecture: 'android_arm64',
      )?.name,
      'whisper-0.0.48-android-arm64-v8a.apk',
    );
    expect(
      selectUpdateAsset(
        assets,
        platform: AppUpdatePlatform.android,
        architecture: 'unknown',
      )?.name,
      'whisper-0.0.48-android-universal.apk',
    );
  });

  test('a signature goes with its package and is never taken for one', () {
    final linux = <Map<String, Object?>>[
      _asset('whisper-0.0.48-linux-x86_64.AppImage.sig'),
      _asset('whisper-0.0.48-linux-x86_64.AppImage'),
    ];
    final chosen = selectUpdateAsset(
      linux,
      platform: AppUpdatePlatform.linux,
      architecture: 'linux_x64',
    );
    expect(chosen?.name, 'whisper-0.0.48-linux-x86_64.AppImage');
    expect(chosen?.signatureUrl?.path, endsWith('.AppImage.sig'));
    expect(
      selectUpdateAsset(
        linux.sublist(0, 1),
        platform: AppUpdatePlatform.linux,
        architecture: 'linux_x64',
      ),
      isNull,
    );
  });

  test('untrusted download URLs are ignored', () {
    final asset = selectUpdateAsset(
      <Map<String, Object?>>[
        <String, Object?>{
          'name': 'whisper-0.0.48-windows-x86_64.exe',
          'size': 1024,
          'digest': 'sha256:$_digest',
          'browser_download_url': 'https://example.com/update.exe',
        },
      ],
      platform: AppUpdatePlatform.windows,
      architecture: 'windows_x64',
    );

    expect(asset, isNull);
  });

  test('assets without a GitHub SHA-256 digest are not installable', () {
    final asset = selectUpdateAsset(
      <Map<String, Object?>>[
        <String, Object?>{
          'name': 'whisper-0.0.48-windows-x86_64.exe',
          'size': 1024,
          'browser_download_url':
              'https://github.com/lawnvi/whisper/releases/download/dev-v0.0.48/update.exe',
        },
      ],
      platform: AppUpdatePlatform.windows,
      architecture: 'windows_x64',
    );

    expect(asset, isNull);
  });

  test('semantic version comparison is numeric', () {
    expect(compareAppVersions('0.0.10', '0.0.9'), greaterThan(0));
    expect(compareAppVersions('1.0.0', '0.99.99'), greaterThan(0));
    expect(compareAppVersions('v2.4.0+12', '2.4.0'), 0);
  });

  test('hedged check, zero-wait website routing, and slow-GitHub fallback', () async {
    final tempDir = await Directory.systemTemp.createTemp('whisper-mirror-');
    addTearDown(() => tempDir.delete(recursive: true));
    final payload = List<int>.generate(1024, (i) => i & 0xff);
    final digest = sha256.convert(payload).toString();
    final signature = await _sign(
      'dev-v0.0.60',
      'whisper-0.0.60-macos-arm64.dmg',
      digest,
    );
    final body = jsonEncode([
      _release(
        tag: 'dev-v0.0.60',
        assets: [
          {
            'name': 'whisper-0.0.60-macos-arm64.dmg',
            'size': payload.length,
            'digest': 'sha256:$digest',
            'browser_download_url':
                'https://github.com/lawnvi/whisper/releases/download/dev-v0.0.60/whisper-0.0.60-macos-arm64.dmg',
          },
          {
            'name': 'whisper-0.0.60-macos-arm64.dmg.sig',
            'size': signature.length,
            'digest': 'sha256:${sha256.convert(utf8.encode(signature))}',
            'browser_download_url':
                'https://github.com/lawnvi/whisper/releases/download/dev-v0.0.60/whisper-0.0.60-macos-arm64.dmg.sig',
          },
        ],
      ),
    ]);

    var slowGithubApi = false;
    var throttleGithubDownload = false;
    final hits = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((req) async {
      final host = req.headers.value('x-host')!;
      hits.add('$host${req.uri.path}');
      if (host == 'api.github.com' && slowGithubApi) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (req.uri.path.endsWith('/releases')) {
        req.response.write(body);
      } else if (req.uri.path.endsWith('.sig')) {
        req.response.write(signature);
      } else if (host == 'github.com' && throttleGithubDownload) {
        req.response.bufferOutput = false;
        req.response.add(payload.sublist(0, 64));
        await req.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 120));
        req.response.add(payload.sublist(64));
      } else {
        req.response.add(payload);
      }
      await req.response.close();
    });

    AppUpdateService buildService(String sub) => AppUpdateService(
      platform: AppUpdatePlatform.macos,
      architecture: 'macos_arm64',
      channel: AppUpdateChannel.preview,
      headStart: const Duration(milliseconds: 40),
      slowDownloadWindow: const Duration(milliseconds: 50),
      minBytesInSlowWindow: 512,
      httpClientFactory: () => _LocalRewriteClient(server.port),
      temporaryDirectoryProvider: () async => Directory('${tempDir.path}/$sub'),
      signingKeys: _trustedKeys,
    );

    // 1) Fast GitHub (VPN / overseas): mirror is never contacted; Chinese site opens github.io.
    final vpn = buildService('vpn');
    final checkVpn = await vpn.checkForUpdate(currentVersion: '0.0.59');
    expect(vpn.websiteUri('zh').toString(), 'https://whisper-lan.github.io/zh');
    expect(vpn.websiteUri('es').toString(), 'https://whisper-lan.github.io/en');
    await vpn.downloadUpdate(checkVpn.release!);
    expect(hits.any((h) => h.contains('127014.xyz')), isFalse);

    // 2) Slow GitHub API (no VPN): mirror wins after head-start, download goes straight to mirror without waiting.
    hits.clear();
    slowGithubApi = true;
    final cn = buildService('cn');
    final checkCn = await cn.checkForUpdate(currentVersion: '0.0.59');
    expect(cn.websiteUri('zh').toString(), 'https://whisper.127014.xyz/zh');
    final cnFile = (await cn.downloadUpdate(checkCn.release!)).file;
    expect(await cnFile.readAsBytes(), payload);
    expect(
      hits.last,
      'whisper.127014.xyz/download/dev-v0.0.60/whisper-0.0.60-macos-arm64.dmg',
    );
    expect(hits.where((h) => h.startsWith('github.com/')), isEmpty);

    // 3) GitHub API fast, but GitHub asset download crawls -> switches to mirror automatically.
    hits.clear();
    slowGithubApi = false;
    throttleGithubDownload = true;
    final throttled = buildService('throttled');
    final checkThrottled = await throttled.checkForUpdate(
      currentVersion: '0.0.59',
    );
    final throttledFile = (await throttled.downloadUpdate(
      checkThrottled.release!,
    )).file;
    expect(await throttledFile.readAsBytes(), payload);
    expect(hits.sublist(hits.length - 2), [
      'github.com/lawnvi/whisper/releases/download/dev-v0.0.60/whisper-0.0.60-macos-arm64.dmg',
      'whisper.127014.xyz/download/dev-v0.0.60/whisper-0.0.60-macos-arm64.dmg',
    ]);
  });
}

class _LocalRewriteClient implements HttpClient {
  _LocalRewriteClient(this._port);
  final int _port;
  final HttpClient _inner = HttpClient();
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 30);
  @override
  Future<HttpClientRequest> getUrl(Uri url) async => (await _inner.getUrl(
    url.replace(scheme: 'http', host: '127.0.0.1', port: _port),
  ))..headers.set('x-host', url.host);
  @override
  void close({bool force = false}) => _inner.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
