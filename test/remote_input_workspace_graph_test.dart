import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_workspace_graph.dart';

void main() {
  RemoteInputWorkspaceNode node(
    String peerId,
    int x,
    int y, {
    bool controller = false,
    int width = 100,
    int height = 100,
  }) {
    return RemoteInputWorkspaceNode(
      peerId: peerId,
      topology: RemoteInputTopology(
        platform: 'test',
        displays: <RemoteInputDisplay>[
          RemoteInputDisplay(
            displayId: '$peerId-display',
            name: peerId,
            x: 0,
            y: 0,
            width: width,
            height: height,
            scale: 1,
            isPrimary: true,
          ),
        ],
        updatedAt: 1,
      ),
      offsetX: x,
      offsetY: y,
      isController: controller,
    );
  }

  test('builds bidirectional routes through remote devices', () {
    final graph = RemoteInputWorkspaceGraph.build(<RemoteInputWorkspaceNode>[
      node('a', 0, 0, controller: true),
      node('b', 100, 0),
      node('c', 200, 0),
    ]);

    expect(graph.routes, hasLength(4));
    expect(graph.reachableFrom('a'), unorderedEquals(<String>['a', 'b', 'c']));
    expect(
      graph.routesFrom('b').map((route) => route.sinkPeerId),
      unorderedEquals(<String>['a', 'c']),
    );
  });

  test('does not connect screens that only touch at a corner', () {
    final graph = RemoteInputWorkspaceGraph.build(<RemoteInputWorkspaceNode>[
      node('a', 0, 0, controller: true),
      node('b', 100, 100),
    ]);

    expect(graph.routes, isEmpty);
    expect(graph.reachableFrom('a'), <String>{'a'});
  });

  test('marks overlapping devices as conflicting', () {
    final graph = RemoteInputWorkspaceGraph.build(<RemoteInputWorkspaceNode>[
      node('a', 0, 0, controller: true),
      node('b', 90, 0),
    ]);

    expect(graph.conflictingPeerIds, unorderedEquals(<String>['a', 'b']));
    expect(graph.routes, isEmpty);
  });

  test('filters reachability by available devices', () {
    final graph = RemoteInputWorkspaceGraph.build(<RemoteInputWorkspaceNode>[
      node('a', 0, 0, controller: true),
      node('b', 100, 0),
      node('c', 200, 0),
      node('d', 100, 100),
    ]);

    expect(
      graph.reachableFrom('a', allowedPeerIds: <String>{'a', 'b', 'c'}),
      unorderedEquals(<String>['a', 'b', 'c']),
    );
  });

  test('route ids and local display coordinates are deterministic', () {
    final first = RemoteInputWorkspaceGraph.build(<RemoteInputWorkspaceNode>[
      node('b', 100, 40),
      node('a', 0, 0, controller: true, height: 200),
    ]);
    final second = RemoteInputWorkspaceGraph.build(<RemoteInputWorkspaceNode>[
      node('a', 0, 0, controller: true, height: 200),
      node('b', 100, 40),
    ]);

    expect(
      first.routes.map((route) => route.routeId),
      orderedEquals(second.routes.map((route) => route.routeId)),
    );
    final route = first.routes.singleWhere(
      (candidate) => candidate.sourcePeerId == 'b',
    );
    expect(route.mapping.sourceEdge, RemoteInputEdge.left);
    expect(route.mapping.sourceSegmentStart, 0);
    expect(route.mapping.sourceSegmentEnd, 100);
    expect(route.mapping.sinkSegmentStart, 40);
    expect(route.mapping.sinkSegmentEnd, 140);
  });

  test('snaps near any peer but leaves distant nodes disconnected', () {
    final moving = node('c', 208, 3);
    final near = RemoteInputWorkspaceSnapper.snap(
      moving: moving,
      anchors: <RemoteInputWorkspaceNode>[
        node('a', 0, 0, controller: true),
        node('b', 100, 0),
      ],
      canvasScale: 1,
    );
    final far = RemoteInputWorkspaceSnapper.snap(
      moving: node('d', 250, 0),
      anchors: <RemoteInputWorkspaceNode>[node('a', 0, 0, controller: true)],
      canvasScale: 1,
    );

    expect(near, isNotNull);
    expect(near!.anchorPeerId, 'b');
    expect(near.node.offsetX, 200);
    expect(far, isNull);
  });

  test('magnetizer attaches a distant screen to the workspace', () {
    final connected = RemoteInputWorkspaceMagnetizer.connectAll(
      root: node('a', 0, 0, controller: true),
      nodes: <RemoteInputWorkspaceNode>[node('b', 900, 700)],
      preferredPeerId: 'b',
    );
    final graph = RemoteInputWorkspaceGraph.build(connected.values);

    expect(graph.conflictingPeerIds, isEmpty);
    expect(graph.reachableFrom('a'), unorderedEquals(<String>['a', 'b']));
    expect(connected['b']!.offsetX, isNot(900));
  });

  test('magnetizer preserves an existing remote chain', () {
    final connected = RemoteInputWorkspaceMagnetizer.connectAll(
      root: node('a', 0, 0, controller: true),
      nodes: <RemoteInputWorkspaceNode>[node('b', 100, 0), node('c', 200, 0)],
    );

    expect(connected['b']!.offsetX, 100);
    expect(connected['c']!.offsetX, 200);
    expect(
      RemoteInputWorkspaceGraph.build(connected.values).reachableFrom('a'),
      unorderedEquals(<String>['a', 'b', 'c']),
    );
  });

  test('magnetizer connects a floating cluster with usable edges', () {
    final connected = RemoteInputWorkspaceMagnetizer.connectAll(
      root: node('a', 0, 0, controller: true),
      nodes: <RemoteInputWorkspaceNode>[
        node('b', 800, 300),
        node('c', 900, 300),
      ],
      preferredPeerId: 'b',
    );
    final graph = RemoteInputWorkspaceGraph.build(connected.values);

    expect(graph.conflictingPeerIds, isEmpty);
    expect(graph.reachableFrom('a'), unorderedEquals(<String>['a', 'b', 'c']));
    for (final peerId in <String>['b', 'c']) {
      expect(
        graph.routes.where(
          (route) =>
              route.sourcePeerId == peerId &&
              route.mapping.sourceSegmentEnd -
                      route.mapping.sourceSegmentStart >=
                  96,
        ),
        isNotEmpty,
      );
    }
  });

  test('magnetizer resolves overlaps deterministically', () {
    Map<String, RemoteInputWorkspaceNode> connect(
      List<RemoteInputWorkspaceNode> nodes,
    ) => RemoteInputWorkspaceMagnetizer.connectAll(
      root: node('a', 0, 0, controller: true),
      nodes: nodes,
    );

    final first = connect(<RemoteInputWorkspaceNode>[
      node('c', 40, 20),
      node('b', 30, 10),
    ]);
    final second = connect(<RemoteInputWorkspaceNode>[
      node('b', 30, 10),
      node('c', 40, 20),
    ]);

    expect(
      first.map(
        (key, value) => MapEntry(key, <int>[
          value.bounds.x,
          value.bounds.y,
          value.bounds.width,
          value.bounds.height,
        ]),
      ),
      second.map(
        (key, value) => MapEntry(key, <int>[
          value.bounds.x,
          value.bounds.y,
          value.bounds.width,
          value.bounds.height,
        ]),
      ),
    );
    final graph = RemoteInputWorkspaceGraph.build(first.values);
    expect(graph.conflictingPeerIds, isEmpty);
    expect(graph.reachableFrom('a'), unorderedEquals(<String>['a', 'b', 'c']));
  });
}
