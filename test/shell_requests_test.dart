// ignore: depend_on_referenced_packages
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/shell/shell_requests.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/widget/island/island_activity.dart';

const _device = DeviceData(
  id: 0,
  uid: 'peer',
  name: 'iMac',
  host: '192.168.1.5',
  port: 10002,
  platform: 'macos',
  isServer: true,
  online: true,
  clipboard: true,
  auth: false,
  lastTime: 0,
);

Future<AppLocalizations> _l10n() =>
    AppLocalizations.delegate.load(const Locale('zh'));

PairingRequest _request(PairingReason reason, {Future<void>? cancellation}) =>
    PairingRequest(
      device: _device,
      pairingCode: '123456',
      reason: reason,
      mode: PairingPromptMode.responder,
      cancellation: cancellation,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    final shared = RequestIslandSource.shared;
    for (final a in shared.activities.toList()) {
      shared.settle(a.id);
    }
  });

  test('a pairing answer reaches resolve once and leaves the island', () async {
    final l10n = await _l10n();
    final answers = <bool>[];
    askPairing(l10n, _request(PairingReason.newDevice), answers.add);
    final activity = RequestIslandSource.shared.activities.single;
    expect(activity.kind, IslandKind.request);
    final presenter = activity.presenter as RequestPresenter;
    presenter.answers.first.onTap();
    presenter.answers.first.onTap();
    presenter.answers.last.onTap();
    expect(answers, [true]);
    expect(RequestIslandSource.shared.activities, isEmpty);
  });

  test('a changed identity keeps the warning, not a plain request', () async {
    final l10n = await _l10n();
    askPairing(l10n, _request(PairingReason.identityChanged), (_) {});
    final presenter =
        RequestIslandSource.shared.activities.single.presenter
            as RequestPresenter;
    expect(presenter.title, l10n.pairingIdentityChangedTitle);
    expect(
      presenter.detail,
      contains(l10n.pairingIdentityChangedDescription('iMac')),
    );
    expect(presenter.code, '123 456');
    expect(presenter.warning, isTrue);
  });

  test('cancelled by the other side: gone, and no answer is given', () async {
    final l10n = await _l10n();
    final answers = <bool>[];
    final cancelled = Future<void>.value();
    askPairing(
      l10n,
      _request(PairingReason.newDevice, cancellation: cancelled),
      answers.add,
    );
    await pumpEventQueue();
    expect(RequestIslandSource.shared.activities, isEmpty);
    expect(answers, isEmpty);
  });
}
