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

    test('creates a shared edge segment for offset vertical edges', () {
      const source = RemoteInputDisplay(
        displayId: 'source-main',
        name: 'Built-in',
        x: 0,
        y: 0,
        width: 1440,
        height: 900,
        scale: 2,
        isPrimary: true,
      );
      const sink = RemoteInputDisplay(
        displayId: 'sink-main',
        name: 'Desk',
        x: 1440,
        y: 260,
        width: 1920,
        height: 1080,
        scale: 1,
        isPrimary: true,
      );

      final segment = RemoteInputLayoutGeometry.sharedEdgeSegment(
        source: source,
        sourceEdge: RemoteInputEdge.right,
        sinkInLayout: sink,
        sinkEdge: RemoteInputEdge.left,
      );

      expect(segment, isNotNull);
      expect(segment!.sourceDisplayId, 'source-main');
      expect(segment.sinkDisplayId, 'sink-main');
      expect(segment.start, 260);
      expect(segment.end, 900);
      expect(segment.length, 640);
    });

    test('does not create a segment for non-overlapping edges', () {
      const source = RemoteInputDisplay(
        displayId: 'source-main',
        name: 'Built-in',
        x: 0,
        y: 0,
        width: 1440,
        height: 900,
        scale: 2,
        isPrimary: true,
      );
      const sink = RemoteInputDisplay(
        displayId: 'sink-main',
        name: 'Desk',
        x: 1440,
        y: 960,
        width: 1920,
        height: 1080,
        scale: 1,
        isPrimary: true,
      );

      final segment = RemoteInputLayoutGeometry.sharedEdgeSegment(
        source: source,
        sourceEdge: RemoteInputEdge.right,
        sinkInLayout: sink,
        sinkEdge: RemoteInputEdge.left,
      );

      expect(segment, isNull);
    });

    test('maps entry and return points through the shared segment', () {
      const segment = RemoteInputSharedEdgeSegment(
        sourceDisplayId: 'source-main',
        sinkDisplayId: 'sink-main',
        sourceEdge: RemoteInputEdge.right,
        sinkEdge: RemoteInputEdge.left,
        start: 260,
        end: 900,
      );

      final entryUnit = RemoteInputLayoutGeometry.edgeUnitForCoordinate(
        segment: segment,
        coordinate: 580,
      );
      final returnCoordinate = RemoteInputLayoutGeometry.coordinateForEdgeUnit(
        segment: segment,
        edgeUnit: entryUnit,
      );

      expect(entryUnit, closeTo(0.5, 0.001));
      expect(returnCoordinate, 580);
    });

    test('resolves saved layout into source and sink capture segments', () {
      const sourceTopology = RemoteInputTopology(
        platform: 'macos',
        updatedAt: 1,
        displays: [
          RemoteInputDisplay(
            displayId: 'source-main',
            name: 'Built-in',
            x: 0,
            y: 0,
            width: 1440,
            height: 900,
            scale: 2,
            isPrimary: true,
          ),
        ],
      );
      const sinkTopology = RemoteInputTopology(
        platform: 'windows',
        updatedAt: 1,
        displays: [
          RemoteInputDisplay(
            displayId: 'sink-main',
            name: 'Desk',
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
            scale: 1,
            isPrimary: true,
          ),
        ],
      );
      const saved = RemoteInputSavedLayout(
        sourceDisplayId: 'source-main',
        sinkDisplayId: 'sink-main',
        sourceEdge: RemoteInputEdge.right,
        sinkEdge: RemoteInputEdge.left,
        sinkOffsetX: 1440,
        sinkOffsetY: 260,
        sharedSegmentStart: 260,
        sharedSegmentEnd: 900,
      );

      final resolved = RemoteInputLayoutGeometry.resolveSavedLayout(
        savedLayout: saved,
        sourceTopology: sourceTopology,
        sinkTopology: sinkTopology,
      );

      expect(resolved, isNotNull);
      expect(resolved!.sharedSegment.start, 260);
      expect(resolved.sharedSegment.end, 900);
      expect(resolved.sinkSegmentStart, 0);
      expect(resolved.sinkSegmentEnd, 640);
    });

    test('resolves multiple sink displays on the same shared source edge', () {
      const sourceTopology = RemoteInputTopology(
        platform: 'macos',
        updatedAt: 1,
        displays: [
          RemoteInputDisplay(
            displayId: 'source-main',
            name: 'Built-in',
            x: 0,
            y: 0,
            width: 2000,
            height: 1000,
            scale: 2,
            isPrimary: true,
          ),
        ],
      );
      const sinkTopology = RemoteInputTopology(
        platform: 'macos',
        updatedAt: 1,
        displays: [
          RemoteInputDisplay(
            displayId: 'sink-left',
            name: 'Left',
            x: 0,
            y: 0,
            width: 1000,
            height: 800,
            scale: 1,
            isPrimary: true,
          ),
          RemoteInputDisplay(
            displayId: 'sink-right',
            name: 'Right',
            x: 1000,
            y: 0,
            width: 1000,
            height: 800,
            scale: 1,
            isPrimary: false,
          ),
        ],
      );
      const saved = RemoteInputSavedLayout(
        sourceDisplayId: 'source-main',
        sinkDisplayId: 'sink-left',
        sourceEdge: RemoteInputEdge.top,
        sinkEdge: RemoteInputEdge.bottom,
        sinkOffsetX: 0,
        sinkOffsetY: -800,
        sharedSegmentStart: 0,
        sharedSegmentEnd: 1000,
      );

      final resolved = RemoteInputLayoutGeometry.resolveSavedLayout(
        savedLayout: saved,
        sourceTopology: sourceTopology,
        sinkTopology: sinkTopology,
      );

      expect(resolved, isNotNull);
      expect(resolved!.edgeMappings, hasLength(2));
      expect(resolved.edgeMappings[0].sinkDisplayId, 'sink-left');
      expect(resolved.edgeMappings[0].sourceSegmentStart, 0);
      expect(resolved.edgeMappings[0].sourceSegmentEnd, 1000);
      expect(resolved.edgeMappings[1].sinkDisplayId, 'sink-right');
      expect(resolved.edgeMappings[1].sourceSegmentStart, 1000);
      expect(resolved.edgeMappings[1].sourceSegmentEnd, 2000);
    });

    test('resolves multiple source displays on the same shared sink edge', () {
      const sourceTopology = RemoteInputTopology(
        platform: 'macos',
        updatedAt: 1,
        displays: [
          RemoteInputDisplay(
            displayId: 'source-left',
            name: 'Left',
            x: 0,
            y: 0,
            width: 1000,
            height: 800,
            scale: 1,
            isPrimary: true,
          ),
          RemoteInputDisplay(
            displayId: 'source-right',
            name: 'Right',
            x: 1000,
            y: 0,
            width: 1000,
            height: 800,
            scale: 1,
            isPrimary: false,
          ),
        ],
      );
      const sinkTopology = RemoteInputTopology(
        platform: 'macos',
        updatedAt: 1,
        displays: [
          RemoteInputDisplay(
            displayId: 'sink-main',
            name: 'Desk',
            x: 0,
            y: 0,
            width: 1000,
            height: 700,
            scale: 1,
            isPrimary: true,
          ),
        ],
      );
      const saved = RemoteInputSavedLayout(
        sourceDisplayId: 'source-left',
        sinkDisplayId: 'sink-main',
        sourceEdge: RemoteInputEdge.bottom,
        sinkEdge: RemoteInputEdge.top,
        sinkOffsetX: 500,
        sinkOffsetY: 800,
        sharedSegmentStart: 500,
        sharedSegmentEnd: 1000,
      );

      final resolved = RemoteInputLayoutGeometry.resolveSavedLayout(
        savedLayout: saved,
        sourceTopology: sourceTopology,
        sinkTopology: sinkTopology,
      );

      expect(resolved, isNotNull);
      expect(
        resolved!.edgeMappings.map((mapping) => (
              mapping.sourceDisplayId,
              mapping.sourceEdge,
              mapping.sinkDisplayId,
              mapping.sinkEdge,
              mapping.sourceSegmentStart,
              mapping.sourceSegmentEnd,
              mapping.sinkSegmentStart,
              mapping.sinkSegmentEnd,
            )),
        containsAll([
          (
            'source-left',
            RemoteInputEdge.bottom,
            'sink-main',
            RemoteInputEdge.top,
            500,
            1000,
            0,
            500,
          ),
          (
            'source-right',
            RemoteInputEdge.bottom,
            'sink-main',
            RemoteInputEdge.top,
            1000,
            1500,
            500,
            1000,
          ),
        ]),
      );
    });

    test('resolves adjacent sink displays across different source edges', () {
      const sourceTopology = RemoteInputTopology(
        platform: 'macos',
        updatedAt: 1,
        displays: [
          RemoteInputDisplay(
            displayId: 'source-main',
            name: 'Built-in',
            x: 1000,
            y: 800,
            width: 600,
            height: 400,
            scale: 2,
            isPrimary: true,
          ),
        ],
      );
      const sinkTopology = RemoteInputTopology(
        platform: 'windows',
        updatedAt: 1,
        displays: [
          RemoteInputDisplay(
            displayId: 'sink-left',
            name: 'Left',
            x: 0,
            y: 0,
            width: 1000,
            height: 800,
            scale: 1,
            isPrimary: false,
          ),
          RemoteInputDisplay(
            displayId: 'sink-top',
            name: 'Top',
            x: 1000,
            y: 0,
            width: 600,
            height: 400,
            scale: 1,
            isPrimary: true,
          ),
        ],
      );
      const saved = RemoteInputSavedLayout(
        sourceDisplayId: 'source-main',
        sinkDisplayId: 'sink-top',
        sourceEdge: RemoteInputEdge.top,
        sinkEdge: RemoteInputEdge.bottom,
        sinkOffsetX: 0,
        sinkOffsetY: 400,
        sharedSegmentStart: 1000,
        sharedSegmentEnd: 1600,
      );

      final resolved = RemoteInputLayoutGeometry.resolveSavedLayout(
        savedLayout: saved,
        sourceTopology: sourceTopology,
        sinkTopology: sinkTopology,
      );

      expect(resolved, isNotNull);
      expect(resolved!.edgeMappings, hasLength(2));
      expect(
        resolved.edgeMappings.map((mapping) => (
              mapping.sourceEdge,
              mapping.sinkDisplayId,
              mapping.sinkEdge,
              mapping.sourceSegmentStart,
              mapping.sourceSegmentEnd,
            )),
        containsAll([
          (
            RemoteInputEdge.top,
            'sink-top',
            RemoteInputEdge.bottom,
            1000,
            1600,
          ),
          (
            RemoteInputEdge.left,
            'sink-left',
            RemoteInputEdge.right,
            800,
            1200,
          ),
        ]),
      );
    });

    test('resolves layout when saved sink anchor is not the touching display',
        () {
      const sourceTopology = RemoteInputTopology(
        platform: 'macos',
        updatedAt: 1,
        displays: [
          RemoteInputDisplay(
            displayId: 'dell',
            name: 'DELL P2418D',
            x: 0,
            y: 0,
            width: 2560,
            height: 1440,
            scale: 1,
            isPrimary: true,
          ),
        ],
      );
      const sinkTopology = RemoteInputTopology(
        platform: 'macos',
        updatedAt: 1,
        displays: [
          RemoteInputDisplay(
            displayId: 'redmi',
            name: 'Redmi 27 NQ',
            x: 0,
            y: 0,
            width: 2560,
            height: 1440,
            scale: 1,
            isPrimary: false,
          ),
          RemoteInputDisplay(
            displayId: 'built-in',
            name: 'Built-in Retina Display',
            x: 420,
            y: 1440,
            width: 1710,
            height: 1107,
            scale: 2,
            isPrimary: true,
          ),
        ],
      );
      const saved = RemoteInputSavedLayout(
        sourceDisplayId: 'dell',
        sinkDisplayId: 'built-in',
        sourceEdge: RemoteInputEdge.right,
        sinkEdge: RemoteInputEdge.left,
        sinkOffsetX: 2560,
        sinkOffsetY: 0,
        sharedSegmentStart: 0,
        sharedSegmentEnd: 1440,
      );

      final resolved = RemoteInputLayoutGeometry.resolveSavedLayout(
        savedLayout: saved,
        sourceTopology: sourceTopology,
        sinkTopology: sinkTopology,
      );

      expect(resolved, isNotNull);
      expect(resolved!.sinkDisplay.displayId, 'redmi');
      expect(resolved.sharedSegment.sourceEdge, RemoteInputEdge.right);
      expect(resolved.sharedSegment.sinkEdge, RemoteInputEdge.left);
      expect(resolved.sharedSegment.start, 0);
      expect(resolved.sharedSegment.end, 1440);
      expect(resolved.edgeMappings, hasLength(1));
      expect(resolved.edgeMappings.single.sinkDisplayId, 'redmi');
    });

    test('resolves layout when saved source display id is stale', () {
      const sourceTopology = RemoteInputTopology(
        platform: 'macos',
        updatedAt: 1,
        displays: [
          RemoteInputDisplay(
            displayId: 'dell-current',
            name: 'DELL P2418D',
            x: 0,
            y: 0,
            width: 2560,
            height: 1440,
            scale: 1,
            isPrimary: true,
          ),
        ],
      );
      const sinkTopology = RemoteInputTopology(
        platform: 'macos',
        updatedAt: 1,
        displays: [
          RemoteInputDisplay(
            displayId: 'redmi',
            name: 'Redmi 27 NQ',
            x: -429,
            y: -1440,
            width: 2560,
            height: 1440,
            scale: 1,
            isPrimary: false,
          ),
          RemoteInputDisplay(
            displayId: 'built-in',
            name: 'Built-in Retina Display',
            x: 0,
            y: 0,
            width: 1710,
            height: 1107,
            scale: 2,
            isPrimary: true,
          ),
        ],
      );
      const saved = RemoteInputSavedLayout(
        sourceDisplayId: 'dell-stale',
        sinkDisplayId: 'built-in',
        sourceEdge: RemoteInputEdge.right,
        sinkEdge: RemoteInputEdge.left,
        sinkOffsetX: 2989,
        sinkOffsetY: 1440,
        sharedSegmentStart: 0,
        sharedSegmentEnd: 1440,
      );

      final resolved = RemoteInputLayoutGeometry.resolveSavedLayout(
        savedLayout: saved,
        sourceTopology: sourceTopology,
        sinkTopology: sinkTopology,
      );

      expect(resolved, isNotNull);
      expect(resolved!.sourceDisplay.displayId, 'dell-current');
      expect(resolved.sinkDisplay.displayId, 'redmi');
      expect(resolved.sharedSegment.sourceEdge, RemoteInputEdge.right);
      expect(resolved.sharedSegment.sinkEdge, RemoteInputEdge.left);
      expect(resolved.sharedSegment.start, 0);
      expect(resolved.sharedSegment.end, 1440);
      expect(resolved.sinkSegmentStart, -1440);
      expect(resolved.sinkSegmentEnd, 0);
      expect(resolved.edgeMappings, hasLength(1));
      expect(resolved.edgeMappings.single.sourceDisplayId, 'dell-current');
      expect(resolved.edgeMappings.single.sinkDisplayId, 'redmi');
    });

    test('resolves a nearly touching perpendicular edge within tolerance', () {
      const sourceTopology = RemoteInputTopology(
        platform: 'macos',
        updatedAt: 1,
        displays: [
          RemoteInputDisplay(
            displayId: 'source-main',
            name: 'Built-in',
            x: 0,
            y: 0,
            width: 1710,
            height: 1107,
            scale: 2,
            isPrimary: true,
          ),
        ],
      );
      const sinkTopology = RemoteInputTopology(
        platform: 'windows',
        updatedAt: 1,
        displays: [
          RemoteInputDisplay(
            displayId: 'sink-left',
            name: 'Left',
            x: -3840,
            y: 0,
            width: 3840,
            height: 2160,
            scale: 1,
            isPrimary: false,
          ),
          RemoteInputDisplay(
            displayId: 'sink-top',
            name: 'Top',
            x: 0,
            y: 0,
            width: 1920,
            height: 1080,
            scale: 1,
            isPrimary: true,
          ),
        ],
      );
      const saved = RemoteInputSavedLayout(
        sourceDisplayId: 'source-main',
        sinkDisplayId: 'sink-top',
        sourceEdge: RemoteInputEdge.top,
        sinkEdge: RemoteInputEdge.bottom,
        sinkOffsetX: 6,
        sinkOffsetY: -1080,
        sharedSegmentStart: 6,
        sharedSegmentEnd: 1710,
      );

      final resolved = RemoteInputLayoutGeometry.resolveSavedLayout(
        savedLayout: saved,
        sourceTopology: sourceTopology,
        sinkTopology: sinkTopology,
        edgeTolerance: 6,
      );

      expect(resolved, isNotNull);
      final leftMapping = resolved!.edgeMappings.singleWhere(
        (mapping) => mapping.sourceEdge == RemoteInputEdge.left,
      );
      expect(leftMapping.sinkDisplayId, 'sink-left');
      expect(leftMapping.sinkEdge, RemoteInputEdge.right);
      expect(leftMapping.sourceSegmentStart, 0);
      expect(leftMapping.sourceSegmentEnd, 1080);
    });
  });

  group('RemoteInputTopology', () {
    test('round-trips display topology json', () {
      const topology = RemoteInputTopology(
        platform: 'macos',
        displays: [
          RemoteInputDisplay(
            displayId: '1',
            name: 'Built-in',
            x: 0,
            y: 0,
            width: 1440,
            height: 900,
            scale: 2,
            isPrimary: true,
          ),
          RemoteInputDisplay(
            displayId: '2',
            name: 'Studio',
            x: 0,
            y: -1080,
            width: 1920,
            height: 1080,
            scale: 1,
            isPrimary: false,
          ),
        ],
        updatedAt: 1234,
      );

      final decoded = RemoteInputTopology.fromJson(topology.toJson());

      expect(decoded.platform, 'macos');
      expect(decoded.displays, hasLength(2));
      expect(decoded.primaryDisplay.displayId, '1');
      expect(decoded.virtualBounds.top, -1080);
      expect(decoded.virtualBounds.height, 1980);
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
        layoutVersion: 2,
        layoutJson: RemoteInputSavedLayout(
          sourceDisplayId: 'source-main',
          sinkDisplayId: 'sink-main',
          sourceEdge: RemoteInputEdge.right,
          sinkEdge: RemoteInputEdge.left,
          sinkOffsetX: 1440,
          sinkOffsetY: 260,
          sharedSegmentStart: 260,
          sharedSegmentEnd: 900,
        ).toJsonString(),
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
      expect(loaded.layoutVersion, 2);
      expect(loaded.savedLayout?.sourceDisplayId, 'source-main');
      expect(loaded.savedLayout?.sharedSegmentEnd, 900);
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

    test(
        'skips existing layout version column when upgrading repaired v4 databases',
        () async {
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
                auto_role TEXT NOT NULL DEFAULT 'source',
                layout_version INTEGER NOT NULL DEFAULT 1,
                edge_threshold_px INTEGER NOT NULL DEFAULT 6,
                release_hotkey TEXT NOT NULL DEFAULT 'ctrl+alt+esc',
                updated_at INTEGER NOT NULL
              )
            ''');
            db.execute('''
              INSERT INTO remote_input_layout (
                peer_id, peer_name, x, y, width, height, enabled,
                auto_activate, auto_role, layout_version, edge_threshold_px,
                release_hotkey, updated_at
              ) VALUES (
                'peer-repaired-v4', 'Windows PC', 1000, 0, 900, 600, 1,
                1, 'sink', 1, 6, 'ctrl+alt+esc', 1234
              )
            ''');
            db.execute('PRAGMA user_version = 4');
          },
        ),
      );

      final loaded = await database.fetchRemoteInputLayout('peer-repaired-v4');

      expect(loaded, isNotNull);
      expect(loaded!.layoutVersion, 1);
      expect(loaded.layoutJson, '');
      expect(loaded.autoRoleValue, RemoteInputAutoRole.sink);
    });
  });
}
