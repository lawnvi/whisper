import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'web_transfer_protocol.dart';

/// Visitors are rows in the device table like any device, told apart by this
/// prefix: a Whisper device's id is a UUID and never starts with it.
const webVisitorPrefix = 'web-';

bool isWebVisitorUid(String uid) => uid.startsWith(webVisitorPrefix);

/// The visitor's id here, from the key only its browser knows. This device
/// keeps the id, never the key, so nobody can work out a key from the
/// database and take over someone's session.
String webVisitorUid(String key) {
  final digest = sha256.convert(utf8.encode('whisper-web-visitor:$key'));
  final encoded = base64Url.encode(digest.bytes).replaceAll('=', '');
  return '$webVisitorPrefix${encoded.substring(0, 22)}';
}

/// The platform stored for a visitor, in the spellings the device pictures
/// already know (`deviceKindFor`, `deviceOsFor`).
String webVisitorPlatform(WebHello hello) => switch (hello.os) {
  'ios' => hello.kind == 'tablet' ? 'ipad' : 'ios',
  'android' => 'android',
  'windows' => 'windows',
  'mac' => 'macos',
  'linux' || 'chromeos' => 'linux',
  _ => '',
};

/// A name to start with, the same in every language: what the device is,
/// or the browser when that is all there is. Renamed like any device.
String webVisitorName(WebHello hello) => switch (hello.os) {
  'ios' => hello.kind == 'tablet' ? 'iPad' : 'iPhone',
  'android' => 'Android',
  'windows' => 'Windows',
  'mac' => 'Mac',
  'chromeos' => 'Chromebook',
  'linux' => 'Linux',
  _ => _browserNames[hello.browser] ?? 'Web',
};

const _browserNames = {
  'chrome': 'Chrome',
  'safari': 'Safari',
  'firefox': 'Firefox',
  'edge': 'Edge',
  'opera': 'Opera',
};

/// What the page draws for this device: its `os` and `kind` vocabulary.
({String os, String kind}) webHostLooks(String platform, String kind) => (
  os: switch (platform) {
    'macos' => 'mac',
    'windows' => 'windows',
    'linux' => 'linux',
    'android' => 'android',
    'ios' => 'ios',
    _ => 'other',
  },
  kind: kind,
);
