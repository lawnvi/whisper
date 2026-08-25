import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'package:whisper/helper/clipboard_write_suppression.dart';
import 'package:whisper/helper/local_network_permission.dart';
import 'package:whisper/helper/privacy_log.dart';
import 'package:whisper/remote_input/remote_input_key_translation.dart';
import 'package:whisper/state/ipv4_address_policy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

var logger = Logger();
const LocalUuid = Uuid();
final ClipboardWriteCoordinator _clipboardWriteCoordinator =
    ClipboardWriteCoordinator(
      writer: (content) => Clipboard.setData(ClipboardData(text: content)),
    );

enum LocalOperationKind { localhostCheck, clipboardRead, filePicker }

enum LocalOperationState { failed, selected, canceled }

bool isDesktop() {
  return Platform.isMacOS || Platform.isLinux || Platform.isWindows;
}

bool supportsNativeSystemAudio() {
  return isDesktop();
}

bool supportsNativeRemoteInput() {
  if (Platform.isMacOS || Platform.isWindows) {
    return true;
  }
  if (Platform.isLinux) {
    return (Platform.environment['DISPLAY'] ?? '').trim().isNotEmpty;
  }
  return false;
}

RemoteInputPlatformKind currentRemoteInputPlatformKind() {
  if (Platform.isMacOS) {
    return RemoteInputPlatformKind.macos;
  }
  if (Platform.isWindows) {
    return RemoteInputPlatformKind.windows;
  }
  if (Platform.isLinux) {
    return RemoteInputPlatformKind.linux;
  }
  return RemoteInputPlatformKind.unknown;
}

bool isMobile() {
  return Platform.isAndroid || Platform.isIOS;
}

Future<String> localUUID() async {
  final SharedPreferences sp = await SharedPreferences.getInstance();
  var uuid = sp.getString("_uuid") ?? "";
  if (uuid.isEmpty) {
    uuid = LocalUuid.v4();
    sp.setString("_uuid", uuid);
  }
  return uuid;
}

String formatSize(int size) {
  var tb = size / (1024 * 1024 * 1024 * 1024);
  if (tb > 10) {
    return "${tb.toStringAsFixed(1)} TB";
  }
  if (tb >= 0.9) {
    return "${tb.toStringAsFixed(2)} TB";
  }
  var gb = size / (1024 * 1024 * 1024);
  if (gb > 10) {
    return "${gb.toStringAsFixed(1)} GB";
  }
  if (gb >= 0.9) {
    return "${gb.toStringAsFixed(2)} GB";
  }
  var mb = size / (1024 * 1024);
  if (mb > 10) {
    return "${mb.toStringAsFixed(1)} MB";
  }
  if (mb >= 0.9) {
    return "${mb.toStringAsFixed(2)} MB";
  }
  var kb = size / 1024;
  if (kb > 1) {
    return "${kb.toStringAsFixed(2)} KB";
  }
  return "$size B";
}

String formatTimestamp(int timestamp) {
  DateTime dateTime = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000);
  // 使用 DateFormat 格式化时间
  return DateFormat('yyyy/MM/dd HH:mm:ss').format(dateTime);
}

IconData platformIcon(String platform) {
  switch (platform.trim().toLowerCase()) {
    case 'android':
      return Icons.android_rounded;
    case 'ios':
    case 'iphone':
    case 'ipad':
      return Icons.apple_rounded;
    case 'mac':
    case 'macos':
    case 'darwin':
      return Icons.laptop_mac_rounded;
    case 'windows':
    case 'win32':
      return Icons.window_rounded;
    case 'linux':
      return Icons.terminal_rounded;
    default:
      return Icons.devices_other_rounded;
  }
}

String platformLabel(String platform) {
  switch (platform.trim().toLowerCase()) {
    case 'android':
      return 'Android';
    case 'ios':
    case 'iphone':
    case 'ipad':
      return 'iPhone / iPad';
    case 'mac':
    case 'macos':
    case 'darwin':
      return 'Mac';
    case 'windows':
    case 'win32':
      return 'Windows';
    case 'linux':
      return 'Linux';
    default:
      final value = platform.trim();
      return value.isEmpty ? 'Unknown' : value;
  }
}

Future<String> deviceName() async {
  final dp = DeviceInfoPlugin();
  try {
    if (kIsWeb) {
      var data = await dp.webBrowserInfo;
      return data.browserName.name;
    } else {
      switch (defaultTargetPlatform) {
        case TargetPlatform.android:
          var android = await dp.androidInfo;
          if (android.model.contains(android.brand)) {
            return android.model;
          }
          return "${android.brand} ${android.model}";
        case TargetPlatform.iOS:
          var ios = await dp.iosInfo;
          return ios.name;
        case TargetPlatform.linux:
          var linux = await dp.linuxInfo;
          return linux.name;
        case TargetPlatform.windows:
          var windows = await dp.windowsInfo;
          return windows.computerName;
        case TargetPlatform.macOS:
          var mac = await dp.macOsInfo;
          return mac.computerName;
        case TargetPlatform.fuchsia:
          return "unknown";
      }
    }
  } on PlatformException {
    return "unknown";
  }
}

Future<bool> isLocalhost(String address) async {
  try {
    for (var interface in await NetworkInterface.list()) {
      for (var addr in interface.addresses) {
        if (!addr.isLoopback &&
            addr.type == InternetAddressType.IPv4 &&
            addr.address == address) {
          return true;
        }
      }
    }
  } catch (error) {
    privacyLog.event(PrivacyEvent.localOperation, <PrivacyField, Object>{
      PrivacyField.kind: LocalOperationKind.localhostCheck,
      PrivacyField.state: LocalOperationState.failed,
      PrivacyField.errorType: privacyLog.errorType(error),
    });
  }

  return false;
}

Future<String> getLocalIpAddress() async {
  if (Platform.isAndroid) {
    final nativeAddress = await LocalNetworkPermission().currentLanAddress();
    if (nativeAddress != null &&
        Ipv4AddressPolicy.isUsableUnicast(nativeAddress)) {
      return nativeAddress;
    }
  }

  try {
    final candidates = <LocalIpv4Candidate>[];
    for (final interface in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: true,
    )) {
      for (var addr in interface.addresses) {
        if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
          candidates.add((
            address: addr.address,
            interfaceName: interface.name,
          ));
        }
      }
    }
    return selectLocalIpv4Address(candidates) ?? '127.0.0.1';
  } on SocketException {
    return '127.0.0.1';
  }
}

typedef LocalIpv4Candidate = ({String address, String interfaceName});

String? selectLocalIpv4Address(Iterable<LocalIpv4Candidate> candidates) {
  LocalIpv4Candidate? best;
  var bestScore = -1;
  for (final candidate in candidates) {
    final score = _localIpv4CandidateScore(candidate);
    if (score > bestScore) {
      best = candidate;
      bestScore = score;
    }
  }
  return best?.address;
}

int _localIpv4CandidateScore(LocalIpv4Candidate candidate) {
  final address = candidate.address;
  if (!Ipv4AddressPolicy.isUsableUnicast(address)) {
    return -1;
  }

  // Physical LAN interfaces outrank Docker, VPN, and tunnel addresses. A
  // virtual address remains a fallback for uncommon but valid configurations.
  final interfaceScore = _isLikelyVirtualInterface(candidate.interfaceName)
      ? 0
      : 100;
  final addressScore = Ipv4AddressPolicy.isPrivate(address)
      ? 30
      : Ipv4AddressPolicy.isLinkLocal(address)
      ? 10
      : 20;
  return interfaceScore + addressScore;
}

bool _isLikelyVirtualInterface(String name) {
  final normalized = name.toLowerCase();
  const prefixes = <String>[
    'docker',
    'br-',
    'virbr',
    'veth',
    'vmnet',
    'vboxnet',
    'utun',
    'tun',
    'tap',
    'wg',
    'tailscale',
    'zt',
    'ppp',
    'ipsec',
    'gif',
    'stf',
    'awdl',
    'llw',
    'anpi',
    'bridge',
  ];
  const markers = <String>['virtual', 'vmware', 'hyper-v', 'vpn'];
  return prefixes.any(normalized.startsWith) ||
      markers.any(normalized.contains);
}

Future<String?> getClipboardText() async {
  return await Clipboard.getData(Clipboard.kTextPlain)
      .then((value) {
        if (value != null && value.text != null) {
          return value.text;
        } else {
          return null;
        }
      })
      .catchError((error) {
        privacyLog.event(PrivacyEvent.localOperation, <PrivacyField, Object>{
          PrivacyField.kind: LocalOperationKind.clipboardRead,
          PrivacyField.state: LocalOperationState.failed,
          PrivacyField.errorType: privacyLog.errorType(error),
        });
        return null;
      });
}

Future<void> copyToClipboard(
  String content, {
  bool suppressWatcher = false,
  String? sourcePeerId,
}) async {
  try {
    await _clipboardWriteCoordinator.write(
      content,
      sourcePeerId: suppressWatcher ? sourcePeerId : null,
    );
  } catch (_) {
    // Clipboard failures are non-fatal and retain the existing best-effort API.
  }
}

bool shouldIgnoreClipboardSync(String content) {
  return _clipboardWriteCoordinator.suppressions.takeExact(content) != null;
}

void pickFile(var callback) async {
  await FilePicker.platform.getDirectoryPath();
  // 打开文件选择器
  FilePickerResult? result = await FilePicker.platform.pickFiles();

  if (result != null) {
    PlatformFile file = result.files.first;
    privacyLog.event(PrivacyEvent.localOperation, <PrivacyField, Object>{
      PrivacyField.kind: LocalOperationKind.filePicker,
      PrivacyField.state: LocalOperationState.selected,
      PrivacyField.bytes: file.size,
    });
    callback(file.path);
  } else {
    privacyLog.event(PrivacyEvent.localOperation, <PrivacyField, Object>{
      PrivacyField.kind: LocalOperationKind.filePicker,
      PrivacyField.state: LocalOperationState.canceled,
    });
  }
}

final RegExp _verificationKeywordPattern = RegExp(
  r'验证码|驗證碼|校验码|校驗碼|动态码|動態碼|'
  r'verification\s+code|security\s+code|login\s+code|'
  r'auth(?:entication)?\s+code|one[-\s]?time(?:\s+(?:password|passcode|code))?|'
  r'otp|passcode|code|'
  r'c[oó]digo(?:\s+de\s+verificaci[oó]n)?|'
  r'contrase(?:ñ|n)a\s+de\s+un\s+solo\s+uso',
  caseSensitive: false,
);

final RegExp _verificationCodePattern = RegExp(
  r'(?:^|[^\d])((?:\d[\s-]?){4,8})(?=$|[^\d])',
);

const Set<String> _verificationCodeNotificationPackages = {
  'com.android.mms',
  'com.android.messaging',
  'com.google.android.apps.messaging',
  'com.samsung.android.messaging',
  'com.samsung.android.messaging.open',
  'com.oneplus.mms',
  'com.coloros.mms',
  'com.sonyericsson.conversations',
};

bool isVerificationCodeNotificationPackage(String? packageName) {
  final normalizedPackageName = packageName?.trim();
  if (normalizedPackageName == null || normalizedPackageName.isEmpty) {
    return false;
  }
  return _verificationCodeNotificationPackages.contains(normalizedPackageName);
}

String verifyCode(String content) {
  final keywordMatches = _verificationKeywordPattern.allMatches(content);
  if (keywordMatches.isEmpty) {
    return "";
  }

  var bestCode = "";
  int? bestDistance;
  for (final codeMatch in _verificationCodePattern.allMatches(content)) {
    final rawCode = codeMatch.group(1) ?? "";
    final code = rawCode.replaceAll(RegExp(r'[\s-]'), "");
    if (code.length < 4 || code.length > 8) {
      continue;
    }

    final distance = _nearestMatchDistance(codeMatch, keywordMatches);
    if (distance > 80) {
      continue;
    }
    if (bestDistance == null || distance < bestDistance) {
      bestDistance = distance;
      bestCode = code;
    }
  }

  return bestCode;
}

int _nearestMatchDistance(Match codeMatch, Iterable<Match> keywordMatches) {
  var nearest = 1 << 30;
  for (final keywordMatch in keywordMatches) {
    final distance = codeMatch.end < keywordMatch.start
        ? keywordMatch.start - codeMatch.end
        : keywordMatch.end < codeMatch.start
        ? codeMatch.start - keywordMatch.end
        : 0;
    if (distance < nearest) {
      nearest = distance;
    }
  }
  return nearest;
}
