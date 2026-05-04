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
        autoRole: RemoteInputAutoRole.sink.name,
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
      expect(loaded.autoRoleValue, RemoteInputAutoRole.sink);
      expect(loaded.edgeThresholdPx, 6);
    });

    test('repairs null auto role values from existing v4 databases', () async {
      await database.close();
      database = LocalDatabase.forTesting(
        NativeDatabase.memory(
          setup: (db) {
            db.execute('''
              CREATE TABLE remote_input_layout (
                peer_id TEXT NOT NULL PRIMARY KEY,
                peer_name TEXT NOT NULL DEFAULT '',
                x INTEGER NOT NULL DEFAULT 1000,
                y INTEGER NOT NULL DEFAULT 0,
                width INTEGER NOT NULL DEFAULT 900,
                height INTEGER NOT NULL DEFAULT 600,
                enabled INTEGER NOT NULL DEFAULT 0 CHECK (enabled IN (0, 1)),
                auto_activate INTEGER NOT NULL DEFAULT 0 CHECK (auto_activate IN (0, 1)),
                auto_role TEXT,
                edge_threshold_px INTEGER NOT NULL DEFAULT 6,
                release_hotkey TEXT NOT NULL DEFAULT 'ctrl+alt+esc',
                updated_at INTEGER NOT NULL
              )
            ''');
            db.execute('''
              INSERT INTO remote_input_layout (
                peer_id, peer_name, x, y, width, height, enabled,
                auto_activate, auto_role, edge_threshold_px,
                release_hotkey, updated_at
              ) VALUES (
                'peer-null-role', 'Desk PC', 1000, 0, 900, 600, 1,
                1, NULL, 6, 'ctrl+alt+esc', 1234
              )
            ''');
            db.execute('PRAGMA user_version = 4');
          },
        ),
      );

      final loaded = await database.fetchRemoteInputLayout('peer-null-role');

      expect(loaded, isNotNull);
      expect(loaded!.autoRoleValue, RemoteInputAutoRole.source);
    });
  });
}
