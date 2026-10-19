import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/state/peer_profile.dart';

void main() {
  test('audioGroupRejoinV1 capability roundtrips and defaults to false', () {
    const caps = PeerCapabilities(audioGroupRejoinV1: true);
    final decoded = PeerCapabilities.fromJson(caps.toJson());
    expect(decoded.audioGroupRejoinV1, isTrue);
    expect(const PeerCapabilities().audioGroupRejoinV1, isFalse);
    expect(
      PeerCapabilities.fromJson(<String, dynamic>{}).audioGroupRejoinV1,
      isFalse,
    );
  });

  test('workspace graph capability roundtrips', () {
    const caps = PeerCapabilities(remoteInputWorkspaceGraphV1: true);

    final decoded = PeerCapabilities.fromWireJson(caps.toJson());

    expect(decoded.remoteInputWorkspaceGraphV1, isTrue);
  });

  test('legacy wire profiles omit capabilities unknown to protocol 9', () {
    const profile = WirePeerProfile(
      uid: 'peer-a',
      name: 'Peer A',
      platform: 'windows',
      capabilities: PeerCapabilities(
        fileTransferV3: true,
        remoteInputWorkspaceGraphV1: true,
      ),
    );

    final legacy = profile.forProtocolVersion(9);
    final capabilities = legacy.toJson()['capabilities']! as Map;
    expect(capabilities['fileTransferV3'], isTrue);
    expect(capabilities, isNot(contains('remoteInputWorkspaceGraphV1')));

    final decoded = WirePeerProfile.fromJson(legacy.toJson());
    expect(decoded.protocolVersion, 9);
    expect(decoded.capabilities.fileTransferV3, isTrue);
    expect(decoded.capabilities.remoteInputWorkspaceGraphV1, isFalse);
  });

  group('form factor', () {
    const ipad = WirePeerProfile(
      uid: 'ipad',
      name: 'iPad',
      platform: 'ios',
      formFactor: DeviceFormFactor.tablet,
    );

    test('a tablet says so to peers of this version', () {
      final json = ipad.toJson();
      expect(json['formFactor'], 'tablet');
      final decoded = WirePeerProfile.fromJson(json);
      expect(decoded.formFactor, DeviceFormFactor.tablet);
      expect(decoded, ipad);
      // Both ends hash the same profile (the handshake checks it).
      expect(decoded.canonicalDigest(), ipad.canonicalDigest());
      expect(PeerProfile.fromWire(decoded).formFactor, 'tablet');
      expect(PeerProfile.fromWire(decoded).toWireProfile(), ipad);
    });

    test('an older peer (0.0.57 speaks 11) is never sent the field', () {
      final legacy = ipad.forProtocolVersion(11);
      expect(legacy.toJson(), isNot(contains('formFactor')));
      // Its strict parser takes the profile as it always did.
      expect(WirePeerProfile.fromJson(legacy.toJson()).formFactor, isEmpty);
    });

    test('a computer, or an older version, says nothing', () {
      const mac = WirePeerProfile(uid: 'mac', name: 'Mac', platform: 'macos');
      expect(mac.toJson(), isNot(contains('formFactor')));
      expect(WirePeerProfile.fromJson(mac.toJson()).formFactor, isEmpty);
    });

    test('rejects a form factor that is not a short string', () {
      for (final bad in <Object?>['', 42, 'x' * 17]) {
        expect(
          () => WirePeerProfile.fromJson({...ipad.toJson(), 'formFactor': bad}),
          throwsFormatException,
        );
      }
    });
  });

  group('wire display topology validation', () {
    Map<String, Object?> profileWith(Object? topology) => <String, Object?>{
      'uid': 'peer-a',
      'name': 'Peer A',
      'platform': 'macos',
      'protocolVersion': 5,
      'capabilities': const PeerCapabilities().toWireJson(5),
      'displayTopology': topology,
    };

    Map<String, Object?> display({
      String id = 'primary',
      bool primary = true,
    }) => <String, Object?>{
      'displayId': id,
      'name': 'Display',
      'x': 0,
      'y': 0,
      'width': 1920,
      'height': 1080,
      'scale': 2.0,
      'isPrimary': primary,
    };

    Map<String, Object?> topology(List<Object?> displays) => <String, Object?>{
      'platform': 'macos',
      'displays': displays,
      'updatedAt': 1,
    };

    test('accepts a bounded topology and preserves the business model', () {
      final parsed = WirePeerProfile.fromJson(
        profileWith(topology(<Object?>[display()])),
      );

      expect(parsed.displayTopology, isA<RemoteInputTopology>());
      expect(parsed.displayTopology!.primaryDisplay.displayId, 'primary');
    });

    test('rejects unknown fields, wrong types, and excessive nesting', () {
      final unknown = topology(<Object?>[display()]);
      unknown['unexpected'] = true;
      expect(
        () => WirePeerProfile.fromJson(profileWith(unknown)),
        throwsFormatException,
      );

      final wrongType = topology(<Object?>[display()]);
      (wrongType['displays']! as List<Object?>).first = <String, Object?>{
        ...display(),
        'width': '1920',
      };
      expect(
        () => WirePeerProfile.fromJson(profileWith(wrongType)),
        throwsFormatException,
      );

      expect(
        () => WirePeerProfile.fromJson(
          profileWith(topology(<Object?>[List<Object?>.filled(20, const [])])),
        ),
        throwsFormatException,
      );
    });

    test('rejects duplicate ids and invalid primary display counts', () {
      expect(
        () => WirePeerProfile.fromJson(
          profileWith(topology(<Object?>[display(), display()])),
        ),
        throwsFormatException,
      );
      expect(
        () => WirePeerProfile.fromJson(
          profileWith(
            topology(<Object?>[
              display(id: 'a', primary: false),
              display(id: 'b', primary: false),
            ]),
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => WirePeerProfile.fromJson(
          profileWith(topology(<Object?>[display(id: 'a'), display(id: 'b')])),
        ),
        throwsFormatException,
      );
    });

    test('rejects oversized strings, coordinates, dimensions, and scale', () {
      for (final invalid in <Map<String, Object?>>[
        <String, Object?>{
          ...display(),
          'displayId': List<String>.filled(129, 'x').join(),
        },
        <String, Object?>{...display(), 'x': 1000001},
        <String, Object?>{...display(), 'width': 0},
        <String, Object?>{...display(), 'height': 100001},
        <String, Object?>{...display(), 'scale': double.infinity},
        <String, Object?>{...display(), 'scale': 9.0},
      ]) {
        expect(
          () => WirePeerProfile.fromJson(
            profileWith(topology(<Object?>[invalid])),
          ),
          throwsFormatException,
        );
      }
    });

    test('business topology parser remains tolerant outside the wire path', () {
      final topology = RemoteInputTopology.fromJson(<String, dynamic>{
        'displays': <Object?>[
          <String, Object?>{'displayId': 'fallback', 'width': 'invalid'},
        ],
      });

      expect(topology.displays.single.width, 1);
    });
  });
}
