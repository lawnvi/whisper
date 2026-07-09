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

    test('supports the complete RFC1918 IPv4 ranges', () {
      for (final host in <String>[
        '10.0.0.1',
        '10.255.255.254',
        '172.16.0.1',
        '172.31.255.254',
        '192.168.0.1',
        '192.168.255.254',
      ]) {
        final endpoint = PeerEndpoint(host: host, port: 65535);
        expect(endpoint.chatUri.host, host);
        expect(endpoint.chatUri.port, 65535);
      }
    });

    test('supports ordinary and scoped IPv6 without hand-built URLs', () {
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

    test('supports resolved mDNS hostnames', () {
      final endpoint = PeerEndpoint(host: 'peer-name.local', port: 10004);

      expect(endpoint.inputUri.toString(), 'ws://peer-name.local:10004/input');
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
