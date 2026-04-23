import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/message.dart';
import 'package:whisper/socket/svrmanager.dart';
import 'package:whisper/state/peer_profile.dart';

void main() {
  group('PeerProfile resumable transfer capability', () {
    test('round-trips protocol version and resumable transfer capability', () {
      final profile = PeerProfile(
        device: DeviceData(
          id: 1,
          uid: 'peer-a',
          name: 'Peer A',
          host: '127.0.0.1',
          port: 9000,
          password: '',
          platform: 'macos',
          isServer: true,
          online: true,
          clipboard: true,
          auth: true,
          lastTime: 1,
          around: true,
        ),
        trustedPeerIds: const <String>['peer-b'],
        autoApproveNewDevices: false,
        autoConnectEnabled: true,
        protocolVersion: 2,
        capabilities: const PeerCapabilities(fileResumeV1: true),
      );

      final decoded = PeerProfile.fromJson(profile.toJson());

      expect(decoded.protocolVersion, 2);
      expect(decoded.capabilities.fileResumeV1, isTrue);
    });

    test('legacy payload defaults resumable transfer capability to false', () {
      final legacy = PeerProfile.fromJson(<String, dynamic>{
        'id': 1,
        'uid': 'peer-a',
        'name': 'Peer A',
        'host': '127.0.0.1',
        'port': 9000,
        'platform': 'macos',
        'isServer': true,
        'online': true,
        'clipboard': true,
        'auth': true,
        'lastTime': 1,
        'around': true,
      });

      expect(legacy.protocolVersion, 1);
      expect(legacy.capabilities.fileResumeV1, isFalse);
    });
  });

  group('TransferControl', () {
    test('round-trips resumable transfer metadata', () {
      final control = TransferControl(
        action: TransferAction.ready,
        transferId: 'transfer-1',
        name: 'archive.zip',
        size: 1024,
        fileTimestamp: 123456789,
        checksumAlgorithm: 'sha256',
        checksumValue: 'abc123',
        chunkSize: 1024,
        resumeOffset: 512,
        resumeProofHash: 'proof',
        errorCode: '',
        errorMessage: '',
      );

      final decoded = TransferControl.fromJson(control.toJson());

      expect(decoded.action, TransferAction.ready);
      expect(decoded.transferId, 'transfer-1');
      expect(decoded.resumeOffset, 512);
      expect(decoded.checksumAlgorithm, 'sha256');
      expect(decoded.resumeProofHash, 'proof');
    });
  });

  group('resumable transfer checksum mode', () {
    test('treats none as an explicit no-checksum fast path', () {
      expect(
        WsSvrManager.shouldUseTransferChecksum('none', ''),
        isFalse,
      );
      expect(
        WsSvrManager.shouldUseTransferChecksum('none', 'unexpected'),
        isFalse,
      );
      expect(
        WsSvrManager.shouldUseTransferChecksum('sha256', 'abc123'),
        isTrue,
      );
    });
  });

  group('TransferChunkFrame', () {
    test('encodes and decodes transfer id, offset, and payload', () {
      final frame = TransferChunkFrame(
        transferId: 'transfer-1',
        offset: 4096,
        payload: Uint8List.fromList(<int>[1, 2, 3, 4]),
      );

      final encoded = frame.encode();
      final decoded = TransferChunkFrame.decode(encoded);

      expect(decoded.transferId, 'transfer-1');
      expect(decoded.offset, 4096);
      expect(decoded.payload, <int>[1, 2, 3, 4]);
      expect(decoded.payloadLength, 4);
      expect(decoded.payloadInNextFrame, isFalse);
    });

    test('encodes header-only frames for raw payload windows', () {
      final frame = TransferChunkFrame(
        transferId: 'transfer-1',
        offset: 4096,
        payload: Uint8List(0),
        payloadLength: 32 * 1024 * 1024,
        payloadInNextFrame: true,
        payloadChecksum: 'abc123',
      );

      final encoded = frame.encode();
      final decoded = TransferChunkFrame.decode(encoded);

      expect(decoded.transferId, 'transfer-1');
      expect(decoded.offset, 4096);
      expect(decoded.payload, isEmpty);
      expect(decoded.payloadLength, 32 * 1024 * 1024);
      expect(decoded.payloadInNextFrame, isTrue);
      expect(decoded.payloadChecksum, 'abc123');
    });

    test('rejects payloads without the resumable transfer magic header', () {
      final badFrame = Uint8List.fromList(<int>[0, 1, 2, 3, 4, 5]);

      expect(
        () => TransferChunkFrame.decode(badFrame),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
