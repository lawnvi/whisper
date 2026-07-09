import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/peer_endpoint.dart';

void main() {
  group('PeerEndpoint', () {
    test('builds every websocket route with structured Uri fields', () {
      final endpoint = PeerEndpoint(host: '192.168.31.8', port: 10004);

      expect(endpoint.chatUri.toString(), 'ws://192.168.31.8:10004/chat');
      expect(endpoint.audioUri.toString(), 'ws://192.168.31.8:10004/audio');
      expect(endpoint.inputUri.toString(), 'ws://192.168.31.8:10004/input');
      expect(endpoint.chatUri.host, '192.168.31.8');
      expect(endpoint.chatUri.port, 10004);
    });

    test('accepts canonical addresses from every RFC1918 IPv4 range', () {
      for (final host in <String>[
        '10.0.0.1',
        '10.0.0.0',
        '10.255.255.254',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.0.1',
        '192.168.1.255',
        '192.168.255.254',
      ]) {
        final endpoint = PeerEndpoint(host: host, port: 65535);
        expect(endpoint.chatUri.host, host);
        expect(endpoint.chatUri.port, 65535);
      }
    });

    test('rejects non-private, special, and disguised IPv4 addresses', () {
      for (final host in <String>[
        '0.1.2.3',
        '127.0.0.1',
        '127.1',
        '2130706433',
        '169.254.1.2',
        '8.8.8.8',
        '100.64.0.1',
        '172.15.255.254',
        '172.32.0.1',
        '224.0.0.251',
        '255.255.255.255',
        '192.168.001.1',
      ]) {
        expect(
          () => PeerEndpoint(host: host, port: 10004),
          throwsArgumentError,
          reason: host,
        );
      }
    });

    test('accepts ULA, global unicast, and scoped link-local IPv6', () {
      for (final host in <String>[
        'fc00::1',
        'fdff:ffff::1',
        '2000::1',
        '2001:db8::7',
        '3fff:ffff::1',
        'fe80::2%en0',
        'febf::1%4',
      ]) {
        expect(PeerEndpoint(host: host, port: 10004).host, host);
      }

      final global = PeerEndpoint(host: '2001:db8::7', port: 10004);
      final linkLocal = PeerEndpoint(host: 'fe80::2%en0', port: 10004);

      expect(global.chatUri.toString(), 'ws://[2001:db8::7]:10004/chat');
      expect(
        linkLocal.audioUri.toString(),
        'ws://[fe80::2%25en0]:10004/audio',
      );
      expect(linkLocal.host, 'fe80::2%en0');
      expect(linkLocal.audioUri.host, 'fe80::2%25en0');
    });

    test('preserves numeric-looking IPv6 zones through URI encoding', () {
      for (final entry in <String, String>{
        'fe80::1%25': 'ws://[fe80::1%2525]:10004/chat',
        'fe80::1%25foo': 'ws://[fe80::1%2525foo]:10004/chat',
        'fe80::1%en0': 'ws://[fe80::1%25en0]:10004/chat',
      }.entries) {
        final endpoint = PeerEndpoint(host: entry.key, port: 10004);

        expect(endpoint.host, entry.key);
        expect(endpoint.chatUri.toString(), entry.value);
      }
    });

    test('rejects unsafe IPv6 scopes and address classes', () {
      for (final host in <String>[
        '::',
        '::1',
        '::ffff:192.168.1.2',
        '::192.168.1.2',
        'ff02::fb',
        'fe80::1',
        'fc00::1%en0',
        '2001:db8::1%en0',
        'fec0::1',
        '4000::1',
      ]) {
        expect(
          () => PeerEndpoint(host: host, port: 10004),
          throwsArgumentError,
          reason: host,
        );
      }
    });

    test('only accepts and normalizes mDNS local hostnames', () {
      final endpoint = PeerEndpoint(host: 'PEER-Name.Local.', port: 10004);

      expect(endpoint.host, 'peer-name.local');
      expect(endpoint.inputUri.toString(), 'ws://peer-name.local:10004/input');

      for (final host in <String>[
        'localhost',
        'localhost.local',
        'example.com',
        'peer.local.example',
        '123.local',
        '1.2.local',
        '127.0.0.1.local',
        '2130706433.local',
        'peer..local',
      ]) {
        expect(
          () => PeerEndpoint(host: host, port: 10004),
          throwsArgumentError,
          reason: host,
        );
      }
    });

    test('rejects invalid ports and URL-injection host values', () {
      expect(
        () => PeerEndpoint(host: '192.168.1.2', port: 0),
        throwsArgumentError,
      );
      expect(
        () => PeerEndpoint(host: '192.168.1.2', port: 65536),
        throwsArgumentError,
      );
      for (final host in <String>[
        '',
        ' peer.local',
        'ws://peer.local',
        'peer.local/chat',
        '[fe80::1]',
        'fe80::1%',
        'peer',
      ]) {
        expect(
          () => PeerEndpoint(host: host, port: 10004),
          throwsArgumentError,
          reason: host,
        );
      }
    });

    test('uses value equality for endpoint caches', () {
      expect(
        PeerEndpoint(host: 'peer.local', port: 10004),
        PeerEndpoint(host: 'peer.local', port: 10004),
      );
      expect(
        PeerEndpoint(host: 'peer.local', port: 10004).hashCode,
        PeerEndpoint(host: 'peer.local', port: 10004).hashCode,
      );
    });
  });
}
