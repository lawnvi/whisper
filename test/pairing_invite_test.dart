import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/state/pairing_invite.dart';
import 'package:whisper/state/peer_endpoint.dart';

const _peerId = '123e4567-e89b-42d3-a456-426614174000';
const _publicKeyHash = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

String _invite({
  String host = '192.168.1.20',
  String port = '10002',
  String peer = _peerId,
  String pkh = _publicKeyHash,
  String version = '1',
}) {
  return 'whisper://pair?v=$version&host=${Uri.encodeQueryComponent(host)}'
      '&port=$port&peer=$peer&pkh=$pkh';
}

void main() {
  test('round trips a canonical identity-pinned invite', () {
    final invite = PairingInvite(
      host: '192.168.1.20',
      port: 10002,
      peerId: _peerId,
      publicKeyHash: _publicKeyHash,
    );

    expect(PairingInvite.parse(invite.encode()), invite);
    expect(invite.encode(), _invite());
  });

  test('accepts and normalizes exactly the PeerEndpoint host policy', () {
    for (final host in <String>[
      '10.0.0.8',
      '172.16.4.9',
      '192.168.1.8',
      'Whisper-Device.Local.',
      'fc00::1',
      '2001:db8::7',
      'fe80::1%en0',
    ]) {
      final endpoint = PeerEndpoint(host: host, port: 10002);
      final invite = PairingInvite(
        host: host,
        port: 10002,
        peerId: _peerId,
        publicKeyHash: _publicKeyHash,
      );

      expect(invite.host, endpoint.host, reason: host);
      expect(PairingInvite.parse(invite.encode()).host, endpoint.host);
    }
  });

  test('rejects every host class that PeerEndpoint cannot connect to', () {
    for (final host in <String>[
      '8.8.8.8',
      '203.0.113.1',
      '0.0.0.0',
      '127.0.0.1',
      '169.254.3.8',
      '::',
      '::1',
      'ff02::1',
      'fe80::1',
      'example.com',
      'localhost.local',
      '192.168.001.2',
    ]) {
      expect(
        () => PeerEndpoint(host: host, port: 10002),
        throwsArgumentError,
        reason: host,
      );
      expect(
        () => PairingInvite.parse(_invite(host: host)),
        throwsA(
          isA<PairingInviteFormatException>().having(
            (error) => error.reason,
            'reason',
            PairingInviteError.invalidHost,
          ),
        ),
        reason: host,
      );
    }
  });

  test('rejects unknown, duplicate, missing, and malformed query fields', () {
    final valid = _invite();
    for (final value in <String>[
      '$valid&extra=1',
      '$valid&peer=$_peerId',
      valid.replaceFirst('&port=10002', ''),
      valid.replaceFirst('v=1', 'version=1'),
      valid.replaceFirst('host=', 'h%6fst='),
      '$valid#fragment',
      valid.replaceFirst('whisper://pair?', 'whisper://pair/path?'),
      'WHISPER://pair?${Uri.parse(valid).query}',
    ]) {
      expect(
        () => PairingInvite.parse(value),
        throwsA(isA<PairingInviteFormatException>()),
        reason: value,
      );
    }
  });

  test('rejects unsupported versions and non-canonical ports', () {
    expect(
      () => PairingInvite.parse(_invite(version: '2')),
      throwsA(
        isA<PairingInviteFormatException>().having(
          (error) => error.reason,
          'reason',
          PairingInviteError.unsupportedVersion,
        ),
      ),
    );
    for (final port in <String>['0', '01', '65536', '-1', '1.0']) {
      expect(
        () => PairingInvite.parse(_invite(port: port)),
        throwsA(
          isA<PairingInviteFormatException>().having(
            (error) => error.reason,
            'reason',
            PairingInviteError.invalidPort,
          ),
        ),
      );
    }
  });

  test('rejects unbounded, non-canonical identity fields', () {
    expect(
      () => PairingInvite.parse(_invite(peer: 'server-a')),
      throwsA(
        isA<PairingInviteFormatException>().having(
          (error) => error.reason,
          'reason',
          PairingInviteError.invalidPeerId,
        ),
      ),
    );
    expect(
      () => PairingInvite.parse(_invite(pkh: 'not-a-hash')),
      throwsA(
        isA<PairingInviteFormatException>().having(
          (error) => error.reason,
          'reason',
          PairingInviteError.invalidPublicKeyHash,
        ),
      ),
    );
    expect(
      () => PairingInvite.parse(
        List<String>.filled(PairingInvite.maxEncodedLength + 1, 'x').join(),
      ),
      throwsA(
        isA<PairingInviteFormatException>().having(
          (error) => error.reason,
          'reason',
          PairingInviteError.tooLong,
        ),
      ),
    );
  });
}
