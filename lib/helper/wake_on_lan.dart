import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/peer_profile.dart';
import 'helper.dart' show isLikelyVirtualInterface;

/// The network cards this computer is on the LAN with, for others to wake it
/// by later. Phones are never woken this way, so they have none.
Future<List<WakeTarget>> localWakeTargets() async {
  if (!Platform.isMacOS && !Platform.isWindows && !Platform.isLinux) {
    return const <WakeTarget>[];
  }
  try {
    final names = <String>{
      for (final card in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      ))
        if (!isLikelyVirtualInterface(card.name)) card.name,
    };
    final found = Platform.isMacOS
        ? await _macTargets(names)
        : Platform.isWindows
        ? await _windowsTargets(names)
        : _linuxTargets(names);
    // Wired first: it is the one that usually wakes a computer.
    found.sort((a, b) => (b.wired ? 1 : 0) - (a.wired ? 1 : 0));
    return List<WakeTarget>.unmodifiable(
      found.toSet().take(WakeTarget.maxPerDevice),
    );
  } catch (_) {
    return const <WakeTarget>[];
  }
}

Future<List<WakeTarget>> _macTargets(Set<String> names) async {
  final ports = await Process.run('/usr/sbin/networksetup', [
    '-listallhardwareports',
  ]);
  final wireless = <String>{};
  String? port;
  for (final line in LineSplitter.split('${ports.stdout}')) {
    if (line.startsWith('Hardware Port: ')) port = line.substring(15);
    if (line.startsWith('Device: ') && port == 'Wi-Fi') {
      wireless.add(line.substring(8).trim());
    }
  }
  final targets = <WakeTarget>[];
  for (final name in names) {
    // The address in use now: Wi-Fi may use a private one per network.
    final shown = await Process.run('/sbin/ifconfig', [name]);
    final ether = RegExp(
      r'^\s*ether\s+(\S+)',
      multiLine: true,
    ).firstMatch('${shown.stdout}');
    final mac = ether == null ? null : WakeTarget.normalize(ether.group(1)!);
    if (mac != null) {
      targets.add(WakeTarget(mac: mac, wired: !wireless.contains(name)));
    }
  }
  return targets;
}

Future<List<WakeTarget>> _windowsTargets(Set<String> names) async {
  // "Connection Name","Network Adapter","Physical Address","Transport Name"
  final listed = await Process.run('getmac', ['/fo', 'csv', '/nh', '/v']);
  final targets = <WakeTarget>[];
  for (final line in LineSplitter.split('${listed.stdout}')) {
    final fields = RegExp(
      r'"([^"]*)"',
    ).allMatches(line).map((match) => match.group(1)!).toList();
    if (fields.length < 4 || !names.contains(fields[0])) continue;
    final adapter = fields[1].toLowerCase();
    if (isLikelyVirtualInterface(adapter) || adapter.contains('bluetooth')) {
      continue;
    }
    final mac = WakeTarget.normalize(fields[2]);
    if (mac == null) continue;
    final wireless = const [
      'wi-fi',
      'wifi',
      'wireless',
      'wlan',
      '802.11',
    ].any(adapter.contains);
    targets.add(WakeTarget(mac: mac, wired: !wireless));
  }
  return targets;
}

List<WakeTarget> _linuxTargets(Set<String> names) {
  final targets = <WakeTarget>[];
  for (final name in names) {
    final card = '/sys/class/net/$name';
    // Virtual interfaces have no device behind them.
    if (!Directory('$card/device').existsSync()) continue;
    final mac = WakeTarget.normalize(
      File('$card/address').readAsStringSync().trim(),
    );
    if (mac == null) continue;
    final wireless = Directory('$card/wireless').existsSync();
    targets.add(WakeTarget(mac: mac, wired: !wireless));
  }
  return targets;
}

/// What other computers said their cards are, kept so they can be woken
/// while they are asleep and gone from the network.
class WakeTargets extends ChangeNotifier {
  WakeTargets({SharedPreferences? preferences}) : _preferences = preferences;

  static final WakeTargets shared = WakeTargets();

  static const _key = 'wake_targets.v1';

  SharedPreferences? _preferences;
  final _known = <String, List<WakeTarget>>{};
  Future<void>? _loading;

  List<WakeTarget> of(String peerId) => _known[peerId] ?? const [];

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final preferences = _preferences ??=
          await SharedPreferences.getInstance();
      final raw = preferences.getString(_key);
      final map = raw == null ? null : jsonDecode(raw);
      if (map is Map) {
        for (final entry in map.entries) {
          final value = entry.value;
          if (entry.key is! String || value is! List) continue;
          try {
            _known[entry.key as String] = List.unmodifiable(
              value.map(WakeTarget.fromJson),
            );
          } on FormatException {
            // A damaged entry is dropped; the device says it again.
          }
        }
      }
    } catch (_) {
      // Nothing kept: devices are known again once they connect.
    }
    notifyListeners();
  }

  /// [peerId] said which cards can wake it (its profile).
  Future<void> record(String peerId, List<WakeTarget> targets) async {
    await load();
    if (peerId.isEmpty || listEquals(_known[peerId], targets)) return;
    if (targets.isEmpty) {
      _known.remove(peerId);
    } else {
      _known[peerId] = List.unmodifiable(targets);
    }
    notifyListeners();
    try {
      final preferences = _preferences ??=
          await SharedPreferences.getInstance();
      await preferences.setString(
        _key,
        jsonEncode({
          for (final entry in _known.entries)
            entry.key: [for (final target in entry.value) target.toJson()],
        }),
      );
    } catch (_) {
      // Known for this run.
    }
  }

  /// Forgets a device that was removed.
  Future<void> forget(String peerId) => record(peerId, const <WakeTarget>[]);
}

/// The wake-on-LAN "magic packet": six 0xFF bytes, then the card's address
/// sixteen times.
Uint8List magicPacket(String mac) {
  final address = [
    for (final part in mac.split(':')) int.parse(part, radix: 16),
  ];
  return Uint8List.fromList([
    for (var i = 0; i < 6; i++) 0xFF,
    for (var i = 0; i < 16; i++) ...address,
  ]);
}

/// Sends the magic packet for every card of a sleeping computer to the whole
/// network, on each of this device's networks, and to [lastHost] directly.
/// Returns whether any packet left; whether the computer wakes depends on it
/// (a wired card with wake-on-LAN on, and sleep rather than shut down).
Future<bool> sendWakePackets(
  List<WakeTarget> targets, {
  String lastHost = '',
}) async {
  if (targets.isEmpty) return false;
  final destinations = <InternetAddress>{
    InternetAddress('255.255.255.255'),
    if (InternetAddress.tryParse(lastHost) case final host?
        when host.type == InternetAddressType.IPv4)
      host,
  };
  try {
    for (final card in await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    )) {
      if (isLikelyVirtualInterface(card.name)) continue;
      for (final address in card.addresses) {
        if (address.isLoopback || address.isLinkLocal) continue;
        // The netmask isn't known here; most home networks are /24.
        final parts = address.address.split('.');
        destinations.add(InternetAddress('${parts.take(3).join('.')}.255'));
      }
    }
  } catch (_) {
    // The limited broadcast still goes out.
  }
  RawDatagramSocket? socket;
  var sent = false;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    // A few times: a busy network can drop one.
    for (var round = 0; round < 3; round++) {
      for (final target in targets) {
        final packet = magicPacket(target.mac);
        for (final destination in destinations) {
          try {
            sent = socket.send(packet, destination, 9) > 0 || sent;
          } on SocketException {
            // That network isn't reachable from here.
          }
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
  } on SocketException {
    return sent;
  } finally {
    socket?.close();
  }
  return sent;
}
