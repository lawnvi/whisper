import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/remote_input/remote_input_coordinator.dart';
import 'package:whisper/remote_input/remote_input_layout.dart';
import 'package:whisper/remote_input/remote_input_protocol.dart';
import 'package:whisper/remote_input/remote_input_workspace_coordinator.dart';
import 'package:whisper/remote_input/remote_input_workspace_presentation.dart';
import 'package:whisper/remote_input/remote_input_workspace_screen.dart';
import 'package:whisper/theme/app_theme.dart';

void main() {
  testWidgets(
      'real workspace keeps multi-screen coordinates and persists snapped drag',
      (tester) async {
    await _useExpandedViewport(tester);
    final store = _FakeWorkspaceStore(
      devices: <DeviceData>[_device],
      layouts: <String, RemoteInputLayoutData>{'peer-a': _layout},
    );
    final dependencies = RemoteInputWorkspaceDependencies(
      coordinator: _FakeWorkspaceCoordinator(_localTopology),
      socket: _FakeWorkspaceSocket(
        devices: <DeviceData>[_device],
        topologies: <String, RemoteInputTopology>{
          'peer-a': _remoteTopology,
        },
      ),
      store: store,
    );

    await _pumpWorkspace(tester, dependencies);

    final leftDisplay = _remoteVisual('peer-a', 'remote-left');
    final rightDisplay = _remoteVisual('peer-a', 'remote-right');
    final leftRect = tester.getRect(leftDisplay);
    final rightRect = tester.getRect(rightDisplay);
    expect(leftRect.right, closeTo(rightRect.left, 0.5));
    expect(leftRect.top, closeTo(rightRect.top, 0.5));
    expect(
      leftRect.width / rightRect.width,
      closeTo(800 / 600, 0.01),
      reason: 'multi-screen widths must retain their topology ratio',
    );
    expect(leftRect.height / rightRect.height, closeTo(600 / 900, 0.01));

    store.savedLayouts.clear();
    final scale = leftRect.width / 800;
    final gesture = await tester.startGesture(leftRect.center);
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    final acceptedRect = tester.getRect(leftDisplay);
    await gesture.moveBy(const Offset(0, 24));
    await tester.pump();
    final draggedRect = tester.getRect(leftDisplay);
    final draggedRightRect = tester.getRect(rightDisplay);

    expect(draggedRect.top - acceptedRect.top, closeTo(24, 0.6));
    expect(
      draggedRightRect.top - rightRect.top,
      closeTo(draggedRect.top - leftRect.top, 0.01),
    );
    expect(store.savedLayouts, isEmpty,
        reason: 'drag updates remain in memory until pan end');

    final expectedY =
        _layout.y + ((draggedRect.top - leftRect.top) / scale).round();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(store.savedLayouts, hasLength(1));
    final saved = store.savedLayouts.single;
    expect(saved.peerId, 'peer-a');
    expect(saved.x, _localTopology.primaryDisplay.right);
    expect(saved.y, closeTo(expectedY, 1));
    expect(saved.width, _layout.width);
    expect(saved.height, _layout.height);
    expect(saved.layoutVersion, 2);
    expect(saved.layoutJson, isNotEmpty);
    expect(saved.savedLayout?.sinkOffsetX, saved.x);
    expect(saved.savedLayout?.sinkOffsetY, saved.y);
  });

  testWidgets(
      'details removal preserves the inspected device and offers adding it back',
      (tester) async {
    await _useExpandedViewport(tester);
    final dependencies = RemoteInputWorkspaceDependencies(
      coordinator: _FakeWorkspaceCoordinator(_localTopology),
      socket: _FakeWorkspaceSocket(
        devices: <DeviceData>[_device],
        topologies: <String, RemoteInputTopology>{
          'peer-a': _remoteTopology,
        },
      ),
      store: _FakeWorkspaceStore(
        devices: <DeviceData>[_device],
        layouts: <String, RemoteInputLayoutData>{'peer-a': _layout},
      ),
    );

    await _pumpWorkspace(tester, dependencies);
    final details = tester.widget<RemoteInputWorkspaceDetailsPanel>(
      find.byType(RemoteInputWorkspaceDetailsPanel),
    );
    expect(details.deviceName, _device.name);
    expect(details.actionLabel, 'Remove from workspace');
    final removeButton =
        find.widgetWithText(OutlinedButton, 'Remove from workspace');
    expect(removeButton, findsOneWidget);

    await tester.tap(removeButton);
    await tester.pumpAndSettle();

    expect(find.text(_device.name), findsWidgets);
    expect(find.text('Add to workspace'), findsOneWidget);
    expect(
      find.text(
        'Add at least one device from the Devices panel to arrange its screens.',
      ),
      findsOneWidget,
    );
    expect(find.text('No available desktop control targets'), findsNothing);
  });

  testWidgets('canvas reports unavailable devices separately from no selection',
      (tester) async {
    await _useExpandedViewport(tester);
    final dependencies = RemoteInputWorkspaceDependencies(
      coordinator: _FakeWorkspaceCoordinator(_localTopology),
      socket: _FakeWorkspaceSocket(
        devices: const <DeviceData>[],
        topologies: const <String, RemoteInputTopology>{},
      ),
      store: _FakeWorkspaceStore(
        devices: const <DeviceData>[],
        layouts: const <String, RemoteInputLayoutData>{},
      ),
    );

    await _pumpWorkspace(tester, dependencies);

    expect(find.text('No available desktop control targets'), findsWidgets);
    expect(
      find.text(
        'Add at least one device from the Devices panel to arrange its screens.',
      ),
      findsNothing,
    );
  });
}

Future<void> _useExpandedViewport(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpWorkspace(
  WidgetTester tester,
  RemoteInputWorkspaceDependencies dependencies,
) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.lightTheme,
      home: RemoteInputWorkspaceScreen(
        initialDevices: dependencies.socket.connectedRemoteInputDevices(),
        dependencies: dependencies,
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byType(RemoteInputWorkspaceScreen), findsOneWidget);
  expect(tester.takeException(), isNull);
}

Finder _remoteVisual(String peerId, String displayId) {
  return find.descendant(
    of: find.byKey(
      RemoteInputWorkspaceScreen.remoteDisplayKey(peerId, displayId),
    ),
    matching: find.byKey(RemoteInputScreenBlock.visualSurfaceKey),
  );
}

const _device = DeviceData(
  id: 1,
  uid: 'peer-a',
  name: 'Studio desktop',
  host: '192.168.1.20',
  port: 53317,
  platform: 'linux',
  isServer: true,
  online: true,
  clipboard: false,
  auth: true,
  lastTime: 0,
);

const _layout = RemoteInputLayoutData(
  peerId: 'peer-a',
  peerName: 'Studio desktop',
  x: 1200,
  y: 100,
  width: 1400,
  height: 900,
  enabled: true,
  autoActivate: false,
  autoRole: 'source',
  layoutVersion: 1,
  layoutJson: '',
  edgeThresholdPx: 6,
  releaseHotkey: 'ctrl+alt+esc',
  updatedAt: 1,
);

const _localTopology = RemoteInputTopology(
  platform: 'test',
  updatedAt: 1,
  displays: <RemoteInputDisplay>[
    RemoteInputDisplay(
      displayId: 'local-main',
      name: 'Local main',
      x: 0,
      y: 0,
      width: 1200,
      height: 800,
      scale: 1,
      isPrimary: true,
    ),
    RemoteInputDisplay(
      displayId: 'local-left',
      name: 'Local left',
      x: -800,
      y: -1000,
      width: 800,
      height: 3000,
      scale: 1,
      isPrimary: false,
    ),
  ],
);

const _remoteTopology = RemoteInputTopology(
  platform: 'test',
  updatedAt: 1,
  displays: <RemoteInputDisplay>[
    RemoteInputDisplay(
      displayId: 'remote-left',
      name: 'Remote left',
      x: 0,
      y: 0,
      width: 800,
      height: 600,
      scale: 1,
      isPrimary: true,
    ),
    RemoteInputDisplay(
      displayId: 'remote-right',
      name: 'Remote right',
      x: 800,
      y: 0,
      width: 600,
      height: 900,
      scale: 1,
      isPrimary: false,
    ),
  ],
);

class _FakeWorkspaceCoordinator implements RemoteInputWorkspaceCoordinatorApi {
  _FakeWorkspaceCoordinator(this.topology);

  final RemoteInputTopology topology;
  final List<VoidCallback> _listeners = <VoidCallback>[];

  @override
  RemoteInputRuntimeState get legacyState =>
      const RemoteInputRuntimeState.idle();

  @override
  RemoteInputWorkspaceSnapshot get snapshot =>
      const RemoteInputWorkspaceSnapshot.idle();

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  @override
  Future<RemoteInputTopology> loadLocalTopology() async => topology;

  @override
  Future<void> startControllerWorkspace({
    required String sourcePeerId,
    required List<RemoteInputWorkspaceTargetRequest> targets,
    required RemoteInputPeerControlSender sendControlTo,
  }) async {}

  @override
  Future<void> stopControllerWorkspace({
    RemoteInputPeerControlSender? sendControlTo,
  }) async {}
}

class _FakeWorkspaceSocket implements RemoteInputWorkspaceSocketApi {
  const _FakeWorkspaceSocket({
    required this.devices,
    required this.topologies,
  });

  final List<DeviceData> devices;
  final Map<String, RemoteInputTopology> topologies;

  @override
  List<DeviceData> connectedRemoteInputDevices({String preferredPeerId = ''}) {
    return List<DeviceData>.of(devices);
  }

  @override
  bool isConnectedTo(String peerId) =>
      devices.any((item) => item.uid == peerId);

  @override
  RemoteInputTopology? remoteDisplayTopologyFor(String peerId) =>
      topologies[peerId];

  @override
  bool remotePeerTrustsPeer(String remotePeerId, String trustedPeerId) => true;

  @override
  void sendRemoteInputControlTo(
    String peerId,
    RemoteInputControlMessage control,
  ) {}

  @override
  bool supportsRemoteInputFor(String peerId) => true;

  @override
  bool supportsRemoteInputTopologyFor(String peerId) =>
      topologies.containsKey(peerId);
}

class _FakeWorkspaceStore implements RemoteInputWorkspaceStore {
  _FakeWorkspaceStore({
    required List<DeviceData> devices,
    required Map<String, RemoteInputLayoutData> layouts,
  })  : _devices = <String, DeviceData>{
          for (final device in devices) device.uid: device,
        },
        _layouts = Map<String, RemoteInputLayoutData>.of(layouts);

  final Map<String, DeviceData> _devices;
  final Map<String, RemoteInputLayoutData> _layouts;
  final List<RemoteInputLayoutData> savedLayouts = <RemoteInputLayoutData>[];

  @override
  Future<DeviceData?> fetchDevice(String peerId) async => _devices[peerId];

  @override
  Future<RemoteInputLayoutData?> fetchLayout(String peerId) async =>
      _layouts[peerId];

  @override
  Future<void> saveLayout(RemoteInputLayoutData layout) async {
    _layouts[layout.peerId] = layout;
    savedLayouts.add(layout);
  }
}
