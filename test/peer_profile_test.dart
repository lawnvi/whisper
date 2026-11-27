import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/state/peer_profile.dart';

void main() {
  test('workspace graph capability roundtrips', () {
    const caps = PeerCapabilities(remoteInputWorkspaceGraphV1: true);

    final decoded = PeerCapabilities.fromWireJson(caps.toJson());

    expect(decoded.remoteInputWorkspaceGraphV1, isTrue);
  });

  test('future wire profile ignores unknown keys, keeps raw canonical digest, and rejects floats in unknown fields', () {
    const base = WirePeerProfile(
      uid: 'peer-a',
      name: 'Peer A',
      platform: 'windows',
      protocolVersion: 17,
      capabilities: PeerCapabilities(
        fileTransferV3: true,
        remoteInputWorkspaceGraphV1: true,
      ),
    );
    final futureJson = <String, Object?>{
      ...base.toJson(),
      'capabilities': <String, Object?>{
        ...base.capabilities.toJson(),
        'futureFeatureV2': true,
      },
      'futureNested': <String, Object?>{
        'enabled': true,
        'tier': 2,
        'tag': 'v17',
      },
      'futureList': <Object?>['alpha', 42, false],
    };

    final decoded = WirePeerProfile.fromJson(futureJson);
    expect(decoded.protocolVersion, 17);
    expect(decoded.capabilities.fileTransferV3, isTrue);
    expect(decoded.capabilities.remoteInputWorkspaceGraphV1, isTrue);
    // Re-hashing the received raw wire map must differ from stripped toJson()
    // and match a second decode of the same map with reordered keys.
    expect(decoded.canonicalDigest(), isNot(orderedEquals(base.canonicalDigest())));
    final reordered = <String, Object?>{
      'futureList': futureJson['futureList'],
      'futureNested': <String, Object?>{
        'tag': 'v17',
        'tier': 2,
        'enabled': true,
      },
      ...base.toJson(),
      'capabilities': futureJson['capabilities'],
    };
    expect(
      WirePeerProfile.fromJson(reordered).canonicalDigest(),
      orderedEquals(decoded.canonicalDigest()),
    );

    // Floats in unknown fields are rejected so canonical JSON never diverges.
    expect(
      () => WirePeerProfile.fromJson(<String, Object?>{
        ...base.toJson(),
        'futureFloat': 1.5,
      }),
      throwsFormatException,
    );
    expect(
      () => WirePeerProfile.fromJson(<String, Object?>{
        ...base.toJson(),
        'futureNested': <String, Object?>{'ratio': 1.0},
      }),
      throwsFormatException,
    );
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

    test('omits formFactor when empty', () {
      const mac = WirePeerProfile(uid: 'mac', name: 'Mac', platform: 'macos');
      expect(mac.toJson(), isNot(contains('formFactor')));
      expect(WirePeerProfile.fromJson(mac.toJson()).formFactor, isEmpty);
    });

    test('a computer says whether it is a laptop or a desktop', () {
      const mac = WirePeerProfile(
        uid: 'mac',
        name: 'Mac',
        platform: 'macos',
        formFactor: DeviceFormFactor.laptop,
      );
      expect(WirePeerProfile.fromJson(mac.toJson()).formFactor, 'laptop');
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

  group('wake targets', () {
    const desk = WirePeerProfile(
      uid: 'desk',
      name: 'Desk',
      platform: 'windows',
      wake: <WakeTarget>[
        WakeTarget(mac: '00:1a:2b:3c:4d:5e', wired: true),
        WakeTarget(mac: 'a4:5e:60:01:02:03', wired: false),
      ],
    );

    test('a computer sends its cards to peers of this version', () {
      final decoded = WirePeerProfile.fromJson(desk.toJson());
      expect(decoded.wake, desk.wake);
      expect(decoded.canonicalDigest(), desk.canonicalDigest());
      expect(PeerProfile.fromWire(decoded).toWireProfile(), desk);
    });

    test('rejects what is not a short list of unicast addresses', () {
      final good = desk.toJson();
      for (final bad in <Object?>[
        'x',
        List<Object>.filled(5, desk.wake.first.toJson()),
        <Object>[
          <String, Object>{'mac': '00:1A:2B:3C:4D:5E', 'wired': true},
        ],
        <Object>[
          <String, Object>{'mac': '01:00:5e:00:00:01', 'wired': true},
        ],
        <Object>[
          <String, Object>{'mac': '00:00:00:00:00:00', 'wired': true},
        ],
        <Object>[
          <String, Object>{'mac': '00:1a:2b:3c:4d:5e'},
        ],
      ]) {
        expect(
          () => WirePeerProfile.fromJson({...good, 'wake': bad}),
          throwsFormatException,
          reason: '$bad',
        );
      }
    });

    test('reads the spellings systems print', () {
      expect(WakeTarget.normalize('00-1A-2B-3C-4D-5E'), '00:1a:2b:3c:4d:5e');
      expect(WakeTarget.normalize('00:1a:2b:3c:4d:5e'), '00:1a:2b:3c:4d:5e');
      expect(WakeTarget.normalize('N/A'), isNull);
      expect(WakeTarget.normalize('00-00-00-00-00-00'), isNull);
    });
  });

  group('app version', () {
    const desk = WirePeerProfile(
      uid: 'desk',
      name: 'Desk',
      platform: 'windows',
      appVersion: '0.0.61',
    );

    test('goes to peers of this version, and back', () {
      final decoded = WirePeerProfile.fromJson(desk.toJson());
      expect(decoded.appVersion, '0.0.61');
      expect(decoded.canonicalDigest(), desk.canonicalDigest());
      expect(PeerProfile.fromWire(decoded).toWireProfile(), desk);
    });

    test('rejects what is not a short version', () {
      final good = desk.toJson();
      for (final bad in <Object?>['', 42, '0.0.61 beta', 'v' * 33, '0.0.6\n']) {
        expect(
          () => WirePeerProfile.fromJson({...good, 'appVersion': bad}),
          throwsFormatException,
          reason: '$bad',
        );
      }
      expect(
        WirePeerProfile.fromJson({
          ...good,
          'appVersion': '1.2.3+45',
        }).appVersion,
        '1.2.3+45',
      );
    });
  });

  group('wire display topology validation', () {
    Map<String, Object?> profileWith(Object? topology) => <String, Object?>{
      'uid': 'peer-a',
      'name': 'Peer A',
      'platform': 'macos',
      'protocolVersion': 16,
      'capabilities': const PeerCapabilities().toJson(),
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

    test('ignores unknown topology fields while rejecting wrong types and excessive nesting', () {
      final unknown = topology(<Object?>[display()]);
      unknown['futureFlag'] = true;
      expect(
        WirePeerProfile.fromJson(profileWith(unknown)).displayTopology,
        isA<RemoteInputTopology>(),
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
