import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device list composes the responsive workbench from live state', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();

    expect(source, contains('AdaptiveDeviceShell('));
    expect(source, contains('DeviceWorkbenchPane('));
    expect(source, contains('LocalDiscoveryPresentation.fromRuntime('));
    expect(source, contains('ConnectionCoordinator().nearbyCandidates'));
    expect(source, contains('sessions: _sessionItems'));
    expect(source, contains('onSelectSession:'));
    expect(source, contains('_toggleDesktopAudioShare'));
    expect(source, contains('_openRemoteInputWorkspace'));
    expect(source, contains('app_settings.SettingsScreen'));
    expect(source, contains('SendMessageScreen('));
  });

  test('manual connection validates a structured LAN endpoint before connect',
      () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final start = source.indexOf('Future<void> _showManualConnectDialog()');
    final end = source.indexOf('void _openConv(', start);

    expect(start, isNonNegative);
    expect(end, greaterThan(start));
    final method = source.substring(start, end);
    expect(method, contains('showValidatedInputDialog('));
    expect(method, contains('PeerEndpoint('));
    expect(method, contains('validationHostInvalid'));
    expect(method, contains('validationPortInvalid'));
    expect(method, contains('_connectServer(endpoint.host, endpoint.port)'));
    expect(method, isNot(contains('int.parse(')));
    expect(source, isNot(contains('void showInputAlertDialog(')));
  });

  test('local discovery permission and failures remain visible and retryable',
      () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();

    expect(source, contains('LocalNetworkPermissionStatus'));
    expect(source, contains('LocalNetworkPermission().ensureGranted('));
    expect(source, contains('_localDiscoveryErrors'));
    expect(source, contains('_retryLocalDiscovery'));
    expect(source, contains('onRetryDiscovery: _retryLocalDiscovery'));
    final retry = source.substring(
      source.indexOf('Future<void> _retryLocalDiscovery()'),
      source.indexOf(
          'DeviceData buildDevice(',
          source.indexOf(
            'Future<void> _retryLocalDiscovery()',
          )),
    );
    expect(
      RegExp(r'if \(!socketManager\.started\) \{').allMatches(retry),
      hasLength(2),
    );
    expect(
      retry.indexOf('if (!socketManager.started) {'),
      lessThan(retry.indexOf('await _broadcastService(')),
    );
  });

  test('a lost service reconciles through the visible offline snapshot', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final discovery = source.substring(
      source.indexOf(
        'final resolvedDevice = buildDevice(',
      ),
      source.indexOf(
        '_refreshDevice();',
        source.indexOf('final resolvedDevice = buildDevice('),
      ),
    );

    expect(discovery, contains('reconcileDiscoveryDeviceList('));
    expect(discovery, contains('visibleDevice: visibleDevice'));
    expect(discovery, isNot(contains('devices.insert(')));
    expect(discovery, isNot(contains('visibleDevice: temp')));
  });

  test('discovery lifecycle keeps failures isolated by component', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final listener = source.substring(
      source.indexOf('_discovery?.eventStream!.listen'),
      source.indexOf('// Start discovery **after**'),
    );
    final helperStart = source.indexOf('void _clearLocalDiscoveryError(');
    expect(helperStart, isNonNegative);
    final helpers = source.substring(
      helperStart,
      source.indexOf('Future<void> _broadcastService'),
    );

    expect(helpers, contains('_localDiscoveryErrors.clear(component)'));
    expect(listener, contains('_markLocalDiscoveryStarted();'));
    expect(
      listener,
      contains('LocalDiscoveryComponent.discoveryEngine'),
    );
    expect(listener, isNot(contains('_markLocalDiscoveryResolveFailed();')));
    expect(listener, contains('_resolveLimiter.clear('));
    expect(listener, contains('_markLocalDiscoveryStopped();'));
    final startServer = source.substring(
      source.indexOf('Future<void> _startServer('),
      source.indexOf('@override\n  void onPairing',
          source.indexOf('Future<void> _startServer(')),
    );
    expect(
      startServer,
      contains(
        '_clearLocalDiscoveryError(LocalDiscoveryComponent.server)',
      ),
    );
  });

  test('device removal confirms destructively before clearing data', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final start = source.indexOf('Future<void> _removeDevice(DeviceData');
    expect(start, isNonNegative);
    final end = source.indexOf('@Deprecated', start);
    final removal = source.substring(start, end);

    expect(removal, contains('removeDeviceAfterConfirmation('));
    expect(removal, contains('confirm: () => confirmAction('));
    expect(removal, contains('isDestructive: true'));
    expect(removal, contains('LocalDatabase().clearDevices('));
    expect(
      removal.indexOf('confirm: () => confirmAction('),
      lessThan(removal.indexOf('LocalDatabase().clearDevices(')),
    );
  });

  test('connection callbacks ignore disposed and superseded attempts', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final start = source.indexOf('Future<void> _connectServerInternal(');
    final end = source.indexOf('Future<void> _attemptAutoConnect()', start);
    final connect = source.substring(start, end);
    final callback = connect.substring(connect.indexOf('(ok, message) {'));
    final dispose = source.substring(
      source.indexOf('void dispose()'),
      source.indexOf('Future<void> _stopClipboardWatcher'),
    );

    expect(
        source, contains('final ConnectionAttemptTracker _connectionAttempts'));
    expect(connect, contains('_connectionAttempts.begin('));
    expect(callback, contains('if (!mounted ||'));
    expect(callback, contains('_connectionAttempts.isCurrent('));
    expect(
      callback.indexOf('_connectionAttempts.isCurrent('),
      lessThan(callback.indexOf('AppLocalizations.of(context)')),
    );
    expect(connect, contains('finally {'));
    expect(connect, contains('_connectionAttempts.complete('));
    expect(dispose, contains('_connectionAttempts.cancelAll();'));
  });

  test('obsolete device workspace and duplicate details UI are removed', () {
    final source = File('lib/page/deviceList.dart').readAsStringSync();
    final legacyWidget =
        <String>['lib/widget/device', 'workspace.dart'].join('_');
    final legacyState =
        <String>['lib/state/device', 'workspace_state.dart'].join('_');
    final legacyTest =
        <String>['test/device', 'workspace_state_test.dart'].join('_');

    expect(File(legacyWidget).existsSync(), isFalse);
    expect(File(legacyState).existsSync(), isFalse);
    expect(File(legacyTest).existsSync(), isFalse);
    expect(source, isNot(contains('class DeviceDetailsScreen')));
    expect(source, isNot(contains('void showConfirmationDialog(')));
  });
}
