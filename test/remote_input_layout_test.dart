import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';

void main() {
  group('RemoteInputLayoutGeometry', () {
    test('detects right-edge adjacency with partial vertical overlap', () {
      const local = RemoteInputScreenRect(
        x: 0,
        y: 0,
        width: 1000,
        height: 800,
      );
      const peer = RemoteInputScreenRect(
        x: 1000,
        y: 240,
        width: 900,
        height: 600,
      );

      final edge = RemoteInputLayoutGeometry.adjacentEdge(
        local: local,
        peer: peer,
      );

      expect(edge, RemoteInputEdge.right);
    });

    test('detects top-edge adjacency with partial horizontal overlap', () {
      const local = RemoteInputScreenRect(
        x: 0,
        y: 0,
        width: 1000,
        height: 800,
      );
      const peer = RemoteInputScreenRect(
        x: 300,
        y: -600,
        width: 900,
        height: 600,
      );

      final edge = RemoteInputLayoutGeometry.adjacentEdge(
        local: local,
        peer: peer,
      );

      expect(edge, RemoteInputEdge.top);
    });

    test('does not create an edge for separated screens', () {
      const local = RemoteInputScreenRect(
        x: 0,
        y: 0,
        width: 1000,
        height: 800,
      );
      const peer = RemoteInputScreenRect(
        x: 1050,
        y: 0,
        width: 900,
        height: 600,
      );

      final edge = RemoteInputLayoutGeometry.adjacentEdge(
        local: local,
        peer: peer,
      );

      expect(edge, isNull);
    });

    test('snaps a nearby peer screen to the nearest side', () {
      const local = RemoteInputScreenRect(
        x: 0,
        y: 0,
        width: 1000,
        height: 800,
      );
      const peer = RemoteInputScreenRect(
        x: 1026,
        y: 140,
        width: 900,
        height: 600,
      );

      final snapped = RemoteInputLayoutGeometry.snapToNearestEdge(
        local: local,
        peer: peer,
      );

      expect(snapped.x, 1000);
      expect(snapped.y, 140);
      expect(
        RemoteInputLayoutGeometry.adjacentEdge(local: local, peer: snapped),
        RemoteInputEdge.right,
      );
    });

    test('snaps a peer screen above while keeping horizontal overlap', () {
      const local = RemoteInputScreenRect(
        x: 0,
        y: 0,
        width: 1000,
        height: 800,
      );
      const peer = RemoteInputScreenRect(
        x: -120,
        y: -612,
        width: 900,
        height: 600,
      );

      final snapped = RemoteInputLayoutGeometry.snapToNearestEdge(
        local: local,
        peer: peer,
      );

      expect(snapped.x, -120);
      expect(snapped.y, -600);
      expect(
        RemoteInputLayoutGeometry.adjacentEdge(local: local, peer: snapped),
        RemoteInputEdge.top,
      );
    });
  });

  group('RemoteInputLayout persistence', () {
    late LocalDatabase database;

    setUp(() {
      database = LocalDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await database.close();
    });

    test('persists and reloads peer layout by peer id', () async {
      final layout = RemoteInputLayoutData(
        peerId: 'peer-a',
        peerName: 'Desk PC',
        x: 1000,
        y: 0,
        width: 900,
        height: 600,
        enabled: true,
        autoActivate: true,
        edgeThresholdPx: 6,
        releaseHotkey: 'ctrl+alt+esc',
        updatedAt: 1234,
      );

      await database.upsertRemoteInputLayout(layout);
      final loaded = await database.fetchRemoteInputLayout('peer-a');

      expect(loaded, isNotNull);
      expect(loaded!.peerName, 'Desk PC');
      expect(loaded.enabled, isTrue);
      expect(loaded.autoActivate, isTrue);
      expect(loaded.edgeThresholdPx, 6);
    });
  });
}
