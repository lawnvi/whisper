import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop sidebar owns the keyboard mouse workspace entry', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();

    expect(source, contains('RemoteInputWorkspaceScreen'));
    expect(source, contains('_buildDesktopRemoteInputWorkspaceAction'));
    expect(source, contains('Icons.keyboard_alt_outlined'));
  });

  test(
      'embedded conversation no longer exposes the single peer remote input action',
      () {
    final source = File('lib/page/conversation.dart').readAsStringSync();
    final shouldShowRemoteInputAction = RegExp(
      r'bool get _shouldShowRemoteInputAction \{[\s\S]*?\n  \}',
    ).firstMatch(source)!.group(0)!;

    expect(shouldShowRemoteInputAction, contains('!widget.embedded'));
  });

  test('workspace canvas uses live local display topology', () {
    final source = File('lib/remote_input/remote_input_workspace_screen.dart')
        .readAsStringSync();
    final canvas = RegExp(
      r'Widget _buildScreenCanvas\([\s\S]*?Widget _buildPeerScreenBlock',
    ).firstMatch(source)!.group(0)!;

    expect(source, contains('WidgetsBindingObserver'));
    expect(source, contains('RemoteInputTopology _localTopology'));
    expect(source, contains('didChangeMetrics'));
    expect(source, contains('Future<RemoteInputTopology> _loadLocalTopology'));
    expect(source, contains('_reanchorLegacyDefaultLayout'));
    expect(source, contains('saved.layoutJson.isNotEmpty'));
    expect(source, contains('saved.layoutVersion != 1'));
    expect(canvas, contains('_localDisplays'));
    expect(
      canvas,
      isNot(contains(
          'const local = RemoteInputScreenRect(x: 0, y: 0, width: 1000, height: 800);')),
    );
    expect(canvas, isNot(contains("subtitle: '1000 x 800'")));
  });

  test('workspace canvas keeps screen geometry and labels peer resolution', () {
    final source = File('lib/remote_input/remote_input_workspace_screen.dart')
        .readAsStringSync();
    final canvas = RegExp(
      r'Widget _buildScreenCanvas\([\s\S]*?Widget _buildPeerScreenBlock',
    ).firstMatch(source)!.group(0)!;
    final peerBlock = RegExp(
      r'Widget _buildPeerScreenBlock\([\s\S]*?Widget _buildDetailsPanel',
    ).firstMatch(source)!.group(0)!;

    expect(canvas, isNot(contains('math.max(90, w * scale)')));
    expect(canvas, isNot(contains('math.max(64, h * scale)')));
    expect(canvas, contains('math.max(1.0, w * scale)'));
    expect(canvas, contains('math.max(1.0, h * scale)'));
    expect(peerBlock, contains('_displaySizeLabel(display)'));
    expect(source, contains('String _peerScreenSubtitle'));
    expect(source, contains('_displaySizeLabelForLayout'));
    expect(source, contains('LayoutBuilder('));
    expect(source, contains('showSubtitle'));
  });

  test('workspace canvas renders remote topology displays as a draggable group',
      () {
    final source = File('lib/remote_input/remote_input_workspace_screen.dart')
        .readAsStringSync();
    final canvas = RegExp(
      r'Widget _buildScreenCanvas\([\s\S]*?Widget _buildPeerScreenBlock',
    ).firstMatch(source)!.group(0)!;
    final peerBlock = RegExp(
      r'Widget _buildPeerScreenBlock\([\s\S]*?Widget _buildDetailsPanel',
    ).firstMatch(source)!.group(0)!;

    expect(source, contains('_peerDisplaysForLayout'));
    expect(source, contains('_peerLayoutBounds'));
    expect(source, contains('placeSinkTopologyInBounds'));
    expect(canvas, contains('_peerDisplaysForLayout(device, layout)'));
    expect(peerBlock, contains('for (final display in displays)'));
    expect(peerBlock, contains('_displaySizeLabel(display)'));
    expect(peerBlock, contains('final currentLayout'));
    expect(peerBlock, contains('currentLayout.copyWith'));
    expect(peerBlock, isNot(contains('width: size.width,')));
  });

  test('workspace snapping and labels can target any local display', () {
    final source = File('lib/remote_input/remote_input_workspace_screen.dart')
        .readAsStringSync();
    final snapAndSave = RegExp(
      r'Future<void> _snapAndSaveLayout\([\s\S]*?RemoteInputScreenRect _boundsFor',
    ).firstMatch(source)!.group(0)!;
    final legacyPlan = RegExp(
      r'_WorkspaceSharingPlan\? _legacySharingPlan\([\s\S]*?Future<void> _snapAndSaveLayout',
    ).firstMatch(source)!.group(0)!;
    final edgeLabel = RegExp(
      r'String _edgeLabelForLayout\([\s\S]*?String _peerScreenSubtitle',
    ).firstMatch(source)!.group(0)!;

    expect(source, contains('_snapToNearestLocalDisplay'));
    expect(source, contains('_isLocalOuterEdge'));
    expect(source, contains('_legacySharingPlanForDisplay'));
    expect(snapAndSave, contains('_snapToNearestLocalDisplay(layout)'));
    expect(snapAndSave, isNot(contains('local: _localPrimaryRect')));
    expect(legacyPlan, contains('for (final display in topology.displays)'));
    expect(edgeLabel, contains('_legacySharingPlan(layout)'));
    expect(edgeLabel, isNot(contains('local: _localPrimaryRect')));
  });

  test('workspace drag keeps topology layout json in sync', () {
    final source = File('lib/remote_input/remote_input_workspace_screen.dart')
        .readAsStringSync();
    final snapAndSave = RegExp(
      r'Future<void> _snapAndSaveLayout\([\s\S]*?RemoteInputScreenRect _snapToNearestLocalDisplay',
    ).firstMatch(source)!.group(0)!;

    expect(source, contains('_layoutJsonForSnappedLayout'));
    expect(source, contains('savedLayoutForTranslatedSinkTopology'));
    expect(snapAndSave, contains('final updatedLayoutJson'));
    expect(snapAndSave, contains('layoutJson: updatedLayoutJson'));
  });

  test('workspace screen restores live controller targets as selected', () {
    final source = File('lib/remote_input/remote_input_workspace_screen.dart')
        .readAsStringSync();
    final loadWorkspace = RegExp(
      r'Future<void> _loadWorkspace\(\) async \{[\s\S]*?Future<RemoteInputLayoutData> _ensureLayout',
    ).firstMatch(source)!.group(0)!;

    expect(loadWorkspace, contains('final workspaceSnapshot'));
    expect(loadWorkspace, contains('workspaceSnapshot.liveTargetPeerIds'));
    expect(loadWorkspace, contains('final connectedLiveTargetPeerIds'));
    expect(loadWorkspace, contains('_selectedPeerIds'));
    expect(loadWorkspace, contains('addAll(connectedLiveTargetPeerIds)'));
    expect(loadWorkspace, contains('activePeerId'));
  });

  test('socket disconnect clears remote input workspace state', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(source, contains('Future<void> _handlePeerDisconnected('));
    expect(source, contains('await _handlePeerDisconnected('));
    expect(
      source,
      contains('RemoteInputWorkspaceCoordinator.shared.handlePeerDisconnected'),
    );
    expect(
      source,
      contains('RemoteInputCoordinator.shared.state.isForPeer(peerId)'),
    );
    expect(source, contains('RemoteInputCoordinator.shared.stopLocal()'));
  });

  test('workspace screen blocks center their labels', () {
    final source = File('lib/remote_input/remote_input_workspace_screen.dart')
        .readAsStringSync();
    final screenBlock = RegExp(
      r'class _ScreenBlock extends StatelessWidget \{[\s\S]*?class _DetailRow',
    ).firstMatch(source)!.group(0)!;

    expect(
        screenBlock, contains('crossAxisAlignment: CrossAxisAlignment.center'));
    expect(screenBlock, contains('alignment: Alignment.center'));
    expect(screenBlock, contains('textAlign: TextAlign.center'));
  });
}
