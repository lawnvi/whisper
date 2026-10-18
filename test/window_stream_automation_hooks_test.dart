import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:whisper/debug/automation_hooks.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/state/pairing_request.dart';

import '../tool/ws_drive.dart' show vmServiceUri;

PairingRequest _pairing(String peerId, void Function(bool) onResolve) {
  final cancelled = Completer<void>();
  return PairingRequest(
    device: DeviceData(
      id: 0,
      uid: peerId,
      name: 'Phone',
      host: '10.0.0.2',
      port: 10002,
      platform: 'android',
      isServer: false,
      online: true,
      clipboard: true,
      auth: false,
      lastTime: 0,
    ),
    pairingCode: '123456',
    reason: PairingReason.newDevice,
    mode: PairingPromptMode.responder,
    presentation: PairingPresentationBinding(
      sessionCancellation: cancelled.future,
      onResolve: onResolve,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every hook the matrix scripts use is registered', () async {
    final help = await automationHooks['help']!(HookParams({}));
    expect(
      help['methods'],
      containsAll([
        'ws.sources',
        'ws.catalog',
        'ws.open',
        'ws.state',
        'ws.stats',
        'ws.input',
        'ws.viewport',
        'ws.inset',
        'ws.snapshot',
        'ws.pause',
        'ws.resume',
        'ws.stop',
        'ws.closeWindow',
        'ws.offer',
        'ws.offers',
        'ws.acceptOffer',
        'ws.hostStreams',
        'ws.logTail',
        'files.roots',
        'files.browse',
        'files.copy',
        'files.rename',
        'files.mkdir',
        'files.trash',
        'peers.list',
        'peers.connect',
        'peers.pending',
        'peers.accept',
        'peers.reject',
        'settings.get',
        'settings.set',
      ]),
    );
    // Release builds never expose them.
    final source = File('lib/debug/automation_hooks.dart').readAsStringSync();
    expect(source, contains('if (_registered || !kDebugMode)'));
  });

  test('parameters arrive as strings or as one json object', () {
    final params = HookParams.from({
      'json': '{"items": [{"root": "home", "path": "a"}], "x": 0.25}',
      'stream': 'abc',
      'windowId': '42',
      'flag': 'true',
      'isolateId': 'isolates/1',
    });
    expect(params.string('stream'), 'abc');
    expect(params.integer('windowId'), 42);
    expect(params.optDouble('x'), 0.25);
    expect(params.flag('flag'), isTrue);
    expect(params.list('items'), hasLength(1));
    expect(params.has('isolateId'), isFalse);
    expect(() => params.string('missing'), throwsA(isA<HookError>()));
    expect(() => HookParams.from({'json': '[1]'}), throwsA(isA<HookError>()));
  });

  test('settings can be read and changed by name', () async {
    SharedPreferences.setMockInitialValues({'_port': 10002});
    final set = await automationHooks['settings.set']!(
      HookParams({'key': 'port', 'value': '10012'}),
    );
    expect(set['port'], 10012);
    final all = await automationHooks['settings.get']!(HookParams({}));
    expect(all['port'], 10012);
    await expectLater(
      automationHooks['settings.set']!(
        HookParams({'key': 'port', 'value': '80'}),
      ),
      throwsA(isA<HookError>()),
    );
    await expectLater(
      automationHooks['settings.get']!(HookParams({'key': 'secret'})),
      throwsA(isA<HookError>()),
    );
  });

  test('pairing prompts can be answered once, by peer and code', () async {
    final answers = <bool>[];
    final first = _pairing('phone-a', answers.add);
    final second = _pairing('phone-b', answers.add);
    DebugPairingRequests.add(first);
    DebugPairingRequests.add(second);
    final pending = await automationHooks['peers.pending']!(HookParams({}));
    expect((pending['pending'] as List).map((p) => (p as Map)['peerId']), [
      'phone-a',
      'phone-b',
    ]);
    await expectLater(
      automationHooks['peers.accept']!(
        HookParams({'peerId': 'phone-a', 'code': '000000'}),
      ),
      throwsA(isA<HookError>()),
    );
    await automationHooks['peers.accept']!(
      HookParams({'peerId': 'phone-a', 'code': '123456'}),
    );
    expect(answers, [true]);
    // The newest one by default.
    await automationHooks['peers.reject']!(HookParams({}));
    expect(answers, [true, false]);
    // Answered prompts are gone; a dismissed one never shows.
    expect(DebugPairingRequests.pending, isEmpty);
    final dismissed = _pairing('phone-c', answers.add);
    DebugPairingRequests.add(dismissed);
    dismissed.presentation!.dismiss();
    expect(DebugPairingRequests.pending, isEmpty);
  });

  test('no streams means empty lists, unknown ones an error', () async {
    final sessions = await automationHooks['ws.sessions']!(HookParams({}));
    expect(sessions['sessions'], isEmpty);
    await expectLater(
      automationHooks['ws.state']!(HookParams({'stream': 'nope'})),
      throwsA(isA<HookError>()),
    );
  });

  test('ws_drive finds the VM service from what Flutter prints', () {
    expect(vmServiceUri('8181').toString(), 'ws://127.0.0.1:8181/ws');
    expect(
      vmServiceUri('192.168.1.5:8181').toString(),
      'ws://192.168.1.5:8181/ws',
    );
    expect(
      vmServiceUri('http://127.0.0.1:50300/AbCd12=/').toString(),
      'ws://127.0.0.1:50300/AbCd12=/ws',
    );
    expect(
      vmServiceUri('ws://127.0.0.1:50300/AbCd12=/ws').toString(),
      'ws://127.0.0.1:50300/AbCd12=/ws',
    );
  });
}
