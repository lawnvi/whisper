// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/model/file_transfer.dart';
import 'package:whisper/new_ui/shell/shell_island_sources.dart';
import 'package:whisper/new_ui/shell/shell_requests.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/widget/island/island_activity.dart';
import 'package:whisper/widget/island/island_center.dart';

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

  test('a result stays for a moment, then leaves by itself', () {
    fakeAsync((async) {
      NoteIslandSource.shared.note('已发送');
      expect(NoteIslandSource.shared.activities, hasLength(1));
      async.elapse(const Duration(milliseconds: 2500));
      expect(NoteIslandSource.shared.activities, hasLength(1));
      async.elapse(const Duration(milliseconds: 200));
      expect(NoteIslandSource.shared.activities, isEmpty);
    });
  });

  test('a transfer waiting for its device leaves the island', () {
    TransferSnapshot snapshot(FileTransferState state) => TransferSnapshot(
      transferId: 't',
      messageUuid: 'm',
      peerUid: 'p',
      direction: FileTransferDirection.outgoing,
      state: state,
      finalPath: '/a/log.txt',
      tempPath: '',
      size: 100,
      committedBytes: 50,
      lastError: '',
      updatedAt: 0,
    );
    TransferIslandSource.shared.update(
      snapshot(FileTransferState.transferring),
    );
    expect(TransferIslandSource.shared.activities, hasLength(1));
    TransferIslandSource.shared.update(
      snapshot(FileTransferState.waitingReconnect),
    );
    expect(TransferIslandSource.shared.activities, isEmpty);
  });

  test('a request goes first on the island', () {
    final center = IslandCenter();
    addTearDown(center.dispose);
    final source = IslandListSource([
      IslandActivity(
        id: 'copy',
        kind: IslandKind.copy,
        status: IslandStatus.live,
        since: DateTime(2026),
        presenter: const RequestPresenter(title: 'c', detail: '', answers: []),
      ),
      IslandActivity(
        id: 'ask',
        kind: IslandKind.request,
        status: IslandStatus.live,
        since: DateTime(2025),
        presenter: const RequestPresenter(title: 'a', detail: '', answers: []),
      ),
    ]);
    addTearDown(source.dispose);
    center.addSource(source);
    expect(center.featured?.id, 'ask');
  });
}
