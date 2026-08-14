import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

const whisperUpdateChannel = String.fromEnvironment(
  'WHISPER_UPDATE_CHANNEL',
  defaultValue: 'preview',
);

const _githubApiHost = 'api.github.com';
const _githubDownloadHost = 'github.com';
const _releasesApiPath = '/repos/lawnvi/whisper/releases';
const _cacheLifetime = Duration(minutes: 15);
const _requestTimeout = Duration(seconds: 12);

enum AppUpdateChannel { stable, preview }

enum AppUpdatePlatform { android, ios, macos, windows, linux, unsupported }

enum AppUpdateStatus { upToDate, updateAvailable }

enum AppUpdateInstallDisposition { keepRunning, exitApplication }

class AppUpdateException implements Exception {
  const AppUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AppUpdateAsset {
  const AppUpdateAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
    this.sha256,
  });

  final String name;
  final Uri downloadUrl;
  final int size;
  final String? sha256;
}

class AppUpdateRelease {
  const AppUpdateRelease({
    required this.version,
    required this.tagName,
    required this.channel,
    required this.releaseUrl,
    required this.notes,
    required this.publishedAt,
    required this.asset,
  });

  final String version;
  final String tagName;
  final AppUpdateChannel channel;
  final Uri releaseUrl;
  final String notes;
  final DateTime? publishedAt;
  final AppUpdateAsset? asset;
}

class AppUpdateCheckResult {
  const AppUpdateCheckResult({
    required this.status,
    required this.currentVersion,
    this.release,
  });

  final AppUpdateStatus status;
  final String currentVersion;
  final AppUpdateRelease? release;

  bool get hasUpdate => status == AppUpdateStatus.updateAvailable;
}

class AppUpdateDownload {
  const AppUpdateDownload({required this.release, required this.file});

  final AppUpdateRelease release;
  final File file;
}

abstract interface class AppUpdateManager {
  Future<AppUpdateCheckResult> checkForUpdate({
    required String currentVersion,
    bool force = false,
  });

  Future<AppUpdateDownload> downloadUpdate(
    AppUpdateRelease release, {
    void Function(double progress)? onProgress,
  });

  Future<AppUpdateInstallDisposition> openInstaller(
    AppUpdateDownload download,
  );
}

class AppUpdateService implements AppUpdateManager {
  AppUpdateService({
    AppUpdatePlatform? platform,
    String? architecture,
    AppUpdateChannel? channel,
    HttpClient Function()? httpClientFactory,
    Future<Directory> Function()? temporaryDirectoryProvider,
  }) : platform = platform ?? currentAppUpdatePlatform(),
       architecture = architecture ?? Abi.current().toString().toLowerCase(),
       channel = channel ?? configuredAppUpdateChannel(),
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _temporaryDirectoryProvider =
           temporaryDirectoryProvider ?? getTemporaryDirectory;

  static final AppUpdateService shared = AppUpdateService();

  final AppUpdatePlatform platform;
  final String architecture;
  final AppUpdateChannel channel;
  final HttpClient Function() _httpClientFactory;
  final Future<Directory> Function() _temporaryDirectoryProvider;

  AppUpdateCheckResult? _cachedResult;
  DateTime? _cachedAt;
  String? _cachedCurrentVersion;
  Future<AppUpdateCheckResult>? _inFlight;

  @override
  Future<AppUpdateCheckResult> checkForUpdate({
    required String currentVersion,
    bool force = false,
  }) {
    final now = DateTime.now();
    if (!force &&
        _cachedResult != null &&
        _cachedCurrentVersion == currentVersion &&
        _cachedAt != null &&
        now.difference(_cachedAt!) < _cacheLifetime) {
      return Future<AppUpdateCheckResult>.value(_cachedResult);
    }
    if (!force && _inFlight != null) {
      return _inFlight!;
    }

    final request = _fetchUpdate(currentVersion).then((result) {
      _cachedResult = result;
      _cachedCurrentVersion = currentVersion;
      _cachedAt = DateTime.now();
      return result;
    });
    _inFlight = request;
    return request.whenComplete(() {
      if (identical(_inFlight, request)) {
        _inFlight = null;
      }
    });
  }

  Future<AppUpdateCheckResult> _fetchUpdate(String currentVersion) async {
    final uri = Uri.https(_githubApiHost, _releasesApiPath, {
      'per_page': '100',
      'page': '1',
    });
    final client = _httpClientFactory()
      ..connectionTimeout = _requestTimeout
      ..idleTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(uri).timeout(_requestTimeout);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
        ..set(HttpHeaders.userAgentHeader, 'Whisper/$currentVersion')
        ..set('X-GitHub-Api-Version', '2022-11-28');
      final response = await request.close().timeout(_requestTimeout);
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) {
        throw AppUpdateException(
          'GitHub release request failed (${response.statusCode})',
        );
      }
      return parseGitHubReleases(
        body,
        currentVersion: currentVersion,
        channel: channel,
        platform: platform,
        architecture: architecture,
      );
    } on AppUpdateException {
      rethrow;
    } catch (error) {
      throw AppUpdateException('Unable to check for updates: $error');
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<AppUpdateDownload> downloadUpdate(
    AppUpdateRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    final asset = release.asset;
    if (asset == null) {
      throw const AppUpdateException('No compatible update package');
    }
    if (asset.sha256 == null) {
      throw const AppUpdateException('Update package has no SHA-256 digest');
    }
    if (!_isTrustedDownloadUri(asset.downloadUrl)) {
      throw const AppUpdateException('Untrusted update download URL');
    }

    final temporaryDirectory = await _temporaryDirectoryProvider();
    final updateDirectory = Directory(
      p.join(temporaryDirectory.path, 'whisper_updates', release.version),
    );
    await updateDirectory.create(recursive: true);
    final destination = File(p.join(updateDirectory.path, asset.name));
    final partial = File('${destination.path}.part');
    if (await partial.exists()) {
      await partial.delete();
    }

    if (await destination.exists() &&
        await _isDownloadedAssetValid(destination, asset)) {
      onProgress?.call(1);
      return AppUpdateDownload(release: release, file: destination);
    }

    final client = _httpClientFactory()
      ..connectionTimeout = _requestTimeout
      ..idleTimeout = const Duration(seconds: 30);
    try {
      final request = await client.getUrl(asset.downloadUrl);
      request.headers
        ..set(HttpHeaders.acceptHeader, 'application/octet-stream')
        ..set(HttpHeaders.userAgentHeader, 'Whisper updater');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw AppUpdateException(
          'Update download failed (${response.statusCode})',
        );
      }

      final sink = partial.openWrite();
      var received = 0;
      var lastReported = -1.0;
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (asset.size > 0) {
            final progress = (received / asset.size).clamp(0.0, 1.0);
            if (progress - lastReported >= 0.01 || progress == 1) {
              lastReported = progress;
              onProgress?.call(progress);
            }
          }
        }
      } finally {
        await sink.close();
      }

      if (asset.size > 0 && received != asset.size) {
        throw const AppUpdateException('Downloaded update size mismatch');
      }
      if (!await _isDownloadedAssetValid(partial, asset)) {
        throw const AppUpdateException('Downloaded update checksum mismatch');
      }
      if (await destination.exists()) {
        await destination.delete();
      }
      await partial.rename(destination.path);
      onProgress?.call(1);
      return AppUpdateDownload(release: release, file: destination);
    } on AppUpdateException {
      if (await partial.exists()) {
        await partial.delete();
      }
      rethrow;
    } catch (error) {
      if (await partial.exists()) {
        await partial.delete();
      }
      throw AppUpdateException('Unable to download update: $error');
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> _isDownloadedAssetValid(File file, AppUpdateAsset asset) async {
    if (!await file.exists()) {
      return false;
    }
    if (asset.size > 0 && await file.length() != asset.size) {
      return false;
    }
    final expectedHash = asset.sha256;
    if (expectedHash == null) {
      return false;
    }
    final actualHash = await sha256.bind(file.openRead()).first;
    return actualHash.toString().toLowerCase() == expectedHash.toLowerCase();
  }

  @override
  Future<AppUpdateInstallDisposition> openInstaller(
    AppUpdateDownload download,
  ) async {
    if (platform == AppUpdatePlatform.android) {
      var permission = await Permission.requestInstallPackages.status;
      if (!permission.isGranted) {
        permission = await Permission.requestInstallPackages.request();
      }
      if (!permission.isGranted) {
        throw const AppUpdateException('Package install permission denied');
      }
    }

    if (platform == AppUpdatePlatform.linux &&
        download.file.path.toLowerCase().endsWith('.appimage')) {
      final chmod = await Process.run('chmod', <String>[
        '+x',
        download.file.path,
      ]);
      if (chmod.exitCode != 0) {
        throw const AppUpdateException('Unable to prepare AppImage update');
      }
    }

    final result = await OpenFilex.open(download.file.path);
    if (result.type != ResultType.done) {
      throw AppUpdateException(result.message);
    }
    return installDispositionForPlatform(platform);
  }
}

AppUpdateInstallDisposition installDispositionForPlatform(
  AppUpdatePlatform platform,
) {
  final shouldExit = platform == AppUpdatePlatform.macos ||
      platform == AppUpdatePlatform.windows;
  return shouldExit
      ? AppUpdateInstallDisposition.exitApplication
      : AppUpdateInstallDisposition.keepRunning;
}

AppUpdateChannel configuredAppUpdateChannel() {
  return whisperUpdateChannel.toLowerCase() == 'stable'
      ? AppUpdateChannel.stable
      : AppUpdateChannel.preview;
}

AppUpdatePlatform currentAppUpdatePlatform() {
  if (Platform.isAndroid) {
    return AppUpdatePlatform.android;
  }
  if (Platform.isIOS) {
    return AppUpdatePlatform.ios;
  }
  if (Platform.isMacOS) {
    return AppUpdatePlatform.macos;
  }
  if (Platform.isWindows) {
    return AppUpdatePlatform.windows;
  }
  if (Platform.isLinux) {
    return AppUpdatePlatform.linux;
  }
  return AppUpdatePlatform.unsupported;
}

AppUpdateCheckResult parseGitHubReleases(
  String body, {
  required String currentVersion,
  required AppUpdateChannel channel,
  required AppUpdatePlatform platform,
  required String architecture,
}) {
  final decoded = jsonDecode(body);
  if (decoded is! List<dynamic>) {
    throw const AppUpdateException('Invalid GitHub release response');
  }

  final releases = <AppUpdateRelease>[];
  for (final item in decoded) {
    if (item is! Map<String, dynamic> || item['draft'] == true) {
      continue;
    }
    final tagName = item['tag_name'];
    if (tagName is! String) {
      continue;
    }
    final parsedTag = _parseReleaseTag(tagName);
    if (parsedTag == null ||
        (channel == AppUpdateChannel.stable &&
            parsedTag.channel != AppUpdateChannel.stable)) {
      continue;
    }
    final releaseUri = _trustedReleaseUri(item['html_url']);
    if (releaseUri == null) {
      continue;
    }
    final assets = item['assets'];
    final asset = selectUpdateAsset(
      assets is List<dynamic> ? assets : const <dynamic>[],
      platform: platform,
      architecture: architecture,
    );
    releases.add(
      AppUpdateRelease(
        version: parsedTag.version,
        tagName: tagName,
        channel: parsedTag.channel,
        releaseUrl: releaseUri,
        notes: item['body'] is String ? item['body'] as String : '',
        publishedAt: item['published_at'] is String
            ? DateTime.tryParse(item['published_at'] as String)
            : null,
        asset: asset,
      ),
    );
  }

  releases.sort((left, right) {
    final versionOrder = compareAppVersions(right.version, left.version);
    if (versionOrder != 0) {
      return versionOrder;
    }
    return (right.publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
        .compareTo(left.publishedAt ?? DateTime.fromMillisecondsSinceEpoch(0));
  });
  final latest = releases.firstOrNull;
  if (latest == null ||
      compareAppVersions(latest.version, currentVersion) <= 0) {
    return AppUpdateCheckResult(
      status: AppUpdateStatus.upToDate,
      currentVersion: currentVersion,
      release: latest,
    );
  }
  return AppUpdateCheckResult(
    status: AppUpdateStatus.updateAvailable,
    currentVersion: currentVersion,
    release: latest,
  );
}

AppUpdateAsset? selectUpdateAsset(
  List<dynamic> rawAssets, {
  required AppUpdatePlatform platform,
  required String architecture,
}) {
  if (platform == AppUpdatePlatform.ios ||
      platform == AppUpdatePlatform.unsupported) {
    return null;
  }
  final assets = rawAssets
      .whereType<Map<String, dynamic>>()
      .map(_parseAsset)
      .whereType<AppUpdateAsset>()
      .toList(growable: false);
  final arch = architecture.toLowerCase();

  bool hasName(AppUpdateAsset asset, String value) =>
      asset.name.toLowerCase().contains(value.toLowerCase());

  Iterable<AppUpdateAsset> candidates;
  switch (platform) {
    case AppUpdatePlatform.android:
      candidates = assets.where((asset) => asset.name.endsWith('.apk'));
      final preferredArchitecture = arch.contains('arm64')
          ? 'arm64-v8a'
          : arch.contains('arm')
          ? 'armeabi-v7a'
          : arch.contains('x64') || arch.contains('x86_64')
          ? 'x86_64'
          : 'universal';
      return candidates
              .where((asset) => hasName(asset, preferredArchitecture))
              .firstOrNull ??
          candidates.where((asset) => hasName(asset, 'universal')).firstOrNull;
    case AppUpdatePlatform.macos:
      candidates = assets.where((asset) => asset.name.endsWith('.dmg'));
      final preferredArchitecture = arch.contains('arm64') ? 'arm64' : 'x86_64';
      return candidates
              .where((asset) => hasName(asset, preferredArchitecture))
              .firstOrNull ??
          candidates
              .where((asset) => hasName(asset, 'universal'))
              .firstOrNull ??
          candidates.firstOrNull;
    case AppUpdatePlatform.windows:
      return assets
          .where(
            (asset) =>
                asset.name.toLowerCase().contains('windows') &&
                asset.name.toLowerCase().endsWith('.exe'),
          )
          .firstOrNull;
    case AppUpdatePlatform.linux:
      candidates = assets.where((asset) => hasName(asset, 'linux'));
      final extensionPreference = _linuxPackagePreference();
      return candidates
              .where(
                (asset) =>
                    asset.name.toLowerCase().endsWith(extensionPreference),
              )
              .firstOrNull ??
          candidates
              .where((asset) => asset.name.toLowerCase().endsWith('.appimage'))
              .firstOrNull ??
          candidates.firstOrNull;
    case AppUpdatePlatform.ios:
    case AppUpdatePlatform.unsupported:
      return null;
  }
}

int compareAppVersions(String left, String right) {
  final leftVersion = _numericVersion(left);
  final rightVersion = _numericVersion(right);
  if (leftVersion == null || rightVersion == null) {
    return left.compareTo(right);
  }
  for (var index = 0; index < leftVersion.length; index += 1) {
    final comparison = leftVersion[index].compareTo(rightVersion[index]);
    if (comparison != 0) {
      return comparison;
    }
  }
  return 0;
}

AppUpdateAsset? _parseAsset(Map<String, dynamic> raw) {
  final name = raw['name'];
  final downloadUrl = raw['browser_download_url'];
  if (name is! String || name.isEmpty || downloadUrl is! String) {
    return null;
  }
  final uri = Uri.tryParse(downloadUrl);
  if (uri == null || !_isTrustedDownloadUri(uri)) {
    return null;
  }
  final digest = raw['digest'];
  String? sha256Value;
  if (digest is String && digest.startsWith('sha256:')) {
    final candidate = digest.substring('sha256:'.length).toLowerCase();
    if (RegExp(r'^[a-f0-9]{64}$').hasMatch(candidate)) {
      sha256Value = candidate;
    }
  }
  if (sha256Value == null) {
    return null;
  }
  return AppUpdateAsset(
    name: p.basename(name),
    downloadUrl: uri,
    size: raw['size'] is int ? raw['size'] as int : 0,
    sha256: sha256Value,
  );
}

({AppUpdateChannel channel, String version})? _parseReleaseTag(String tag) {
  final match = RegExp(r'^(dev|release)-v(\d+\.\d+\.\d+)$').firstMatch(tag);
  if (match == null) {
    return null;
  }
  return (
    channel: match.group(1) == 'release'
        ? AppUpdateChannel.stable
        : AppUpdateChannel.preview,
    version: match.group(2)!,
  );
}

List<int>? _numericVersion(String value) {
  final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(value);
  if (match == null) {
    return null;
  }
  return <int>[
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  ];
}

Uri? _trustedReleaseUri(Object? value) {
  if (value is! String) {
    return null;
  }
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.toLowerCase() != _githubDownloadHost) {
    return null;
  }
  return uri;
}

bool _isTrustedDownloadUri(Uri uri) {
  final host = uri.host.toLowerCase();
  return uri.scheme == 'https' &&
      (host == _githubDownloadHost || host.endsWith('.githubusercontent.com'));
}

String _linuxPackagePreference() {
  if (File('/etc/debian_version').existsSync()) {
    return '.deb';
  }
  if (File('/etc/redhat-release').existsSync()) {
    return '.rpm';
  }
  return '.appimage';
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
