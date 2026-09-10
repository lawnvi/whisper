import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/app_update.dart';

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
  group('Debian update installation', () {
    late Directory directory;
    late AppUpdateDownload download;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('whisper-update-test-');
      final file = File('${directory.path}/package with spaces.deb');
      await file.writeAsString('test package');
      final asset = AppUpdateAsset(
        name: 'package with spaces.deb',
        downloadUrl: Uri.parse('https://github.com/lawnvi/whisper/update.deb'),
        size: await file.length(),
        sha256: (await sha256.bind(file.openRead()).first).toString(),
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
      );
    });

    tearDown(() => directory.delete(recursive: true));

    test('waits for apt and passes the installer as one argument', () async {
      var invoked = false;
      final service = AppUpdateService(
        platform: AppUpdatePlatform.linux,
        processRunner: (executable, arguments) async {
          invoked = true;
          expect(executable, '/usr/bin/pkexec');
          expect(arguments, [
            '/usr/bin/apt-get',
            '-y',
            'install',
            '--',
            download.file.absolute.path,
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

    test(
      'does not report success when authorization or installation fails',
      () async {
        for (final exitCode in [126, 127, 100]) {
          final service = AppUpdateService(
            platform: AppUpdatePlatform.linux,
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
          processRunner: (_, _) async => throw StateError('must not execute'),
        );
        await expectLater(
          service.openInstaller(download),
          throwsA(isA<AppUpdateException>()),
        );
      },
    );
  });

  test('preview channel selects the newest recognized release', () {
    final result = parseGitHubReleases(
      jsonEncode(<Map<String, Object?>>[
        _release(tag: 'release-v0.0.47'),
        _release(
          tag: 'dev-v0.0.48',
          assets: <Map<String, Object?>>[
            _asset('whisper-0.0.48-macos-x86_64.dmg'),
            _asset('whisper-0.0.48-macos-arm64.dmg'),
          ],
        ),
        _release(tag: 'nightly-v9.0.0'),
        _release(tag: 'dev-v9.0.0', draft: true),
      ]),
      currentVersion: '0.0.47',
      channel: AppUpdateChannel.preview,
      platform: AppUpdatePlatform.macos,
      architecture: 'macos_arm64',
    );

    expect(result.status, AppUpdateStatus.updateAvailable);
    expect(result.release?.version, '0.0.48');
    expect(result.release?.channel, AppUpdateChannel.preview);
    expect(result.release?.asset?.name, 'whisper-0.0.48-macos-arm64.dmg');
    expect(result.release?.asset?.sha256, _digest);
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

  test('current or newer local version is up to date', () {
    final result = parseGitHubReleases(
      jsonEncode(<Map<String, Object?>>[_release(tag: 'dev-v0.0.48')]),
      currentVersion: '0.0.49',
      channel: AppUpdateChannel.preview,
      platform: AppUpdatePlatform.android,
      architecture: 'android_arm64',
    );

    expect(result.status, AppUpdateStatus.upToDate);
    expect(result.hasUpdate, isFalse);
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

  test('iOS does not offer the unsigned IPA as an installable update', () {
    expect(
      selectUpdateAsset(
        <Map<String, Object?>>[_asset('whisper-0.0.48-ios-unsigned.ipa')],
        platform: AppUpdatePlatform.ios,
        architecture: 'ios_arm64',
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

  test('only Windows and macOS exit after launching an installer', () {
    expect(
      installDispositionForPlatform(AppUpdatePlatform.windows),
      AppUpdateInstallDisposition.exitApplication,
    );
    expect(
      installDispositionForPlatform(AppUpdatePlatform.macos),
      AppUpdateInstallDisposition.exitApplication,
    );
    for (final platform in <AppUpdatePlatform>[
      AppUpdatePlatform.linux,
      AppUpdatePlatform.android,
      AppUpdatePlatform.ios,
      AppUpdatePlatform.unsupported,
    ]) {
      expect(
        installDispositionForPlatform(platform),
        AppUpdateInstallDisposition.keepRunning,
      );
    }
  });
}
