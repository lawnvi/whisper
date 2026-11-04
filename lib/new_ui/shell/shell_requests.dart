import 'package:whisper/theme/radix_colors.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';
import 'package:whisper/new_ui/shell/shell_island.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/remote_files/fs_host.dart';
import 'package:whisper/state/pairing_request.dart';
import 'package:whisper/theme/whisper_icons.dart';
import 'package:whisper/widget/island/island_activity.dart';
import 'package:window_manager/window_manager.dart';

/// One answer to a question on the island.
class IslandAnswer {
  const IslandAnswer(this.label, this.onTap, {this.primary = false});

  final String label;
  final VoidCallback onTap;

  /// White on black: what most people will choose.
  final bool primary;
}

/// Questions other devices ask this one. They stay open on the island until
/// answered or given up on (surfaces.md「灵动岛」: requests do not close when
/// clicking elsewhere), and they replace dialogs that covered the whole window.
class RequestIslandSource extends IslandListSource {
  RequestIslandSource._();

  static final shared = RequestIslandSource._();

  void ask({
    required String id,
    required String title,
    required List<IslandAnswer> answers,
    String detail = '',
    Widget? art,
    String? code,
    bool warning = false,
  }) {
    put(
      IslandActivity(
        id: id,
        kind: IslandKind.request,
        status: IslandStatus.live,
        since: DateTime.now(),
        urgent: true,
        openFor: const Duration(days: 1),
        presenter: RequestPresenter(
          title: title,
          detail: detail,
          answers: answers,
          art: art,
          code: code,
          warning: warning,
        ),
      ),
    );
    unawaited(_raiseWindow());
  }

  /// Answered, or the other side gave up.
  void settle(String id) => remove(id);

  Future<void> _raiseWindow() async {
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    } on Object {
      // The question still shows if the desktop denies activation.
    }
  }
}

class RequestPresenter extends IslandPresenter with MomentViews {
  const RequestPresenter({
    required this.title,
    required this.answers,
    this.detail = '',
    this.art,
    this.code,
    this.warning = false,
  });

  final String title, detail;
  final List<IslandAnswer> answers;

  /// Who is asking, when that is a device.
  final Widget? art;

  /// The digits to compare.
  final String? code;

  /// Not an ordinary question: a device's identity changed.
  final bool warning;

  Widget get _leading => WhisperIcon(
    warning ? WhisperGlyph.warn : WhisperGlyph.ask,
    size: 17,
    color: Radix.amber9,
  );

  @override
  IslandMoment moment(BuildContext context) => IslandMoment(
    leading: _leading,
    title: title,
    detail: detail,
    answers: answers,
    // A warning shows the warning, not the device's picture.
    art: warning
        ? const WhisperIcon(WhisperGlyph.warn, size: 30, color: Radix.amber9)
        : art,
    code: code,
  );

  @override
  Widget glyph(BuildContext context, double size) => _leading;

  @override
  String describe(BuildContext context) =>
      [title, if (detail.isNotEmpty) detail, ?code].join(' ');
}

/// A device asks to browse this one's files.
void askFileBrowse(
  AppLocalizations l10n,
  FileBrowseRequest request,
  void Function(FileBrowseDecision) decide, {
  DeviceData? device,
}) {
  final id = fileBrowseAskId(request.peerId);
  void answer(FileBrowseDecision decision) {
    RequestIslandSource.shared.settle(id);
    decide(decision);
  }

  RequestIslandSource.shared.ask(
    id: id,
    title: l10n.remoteFilesPromptTitle(request.deviceName),
    art: device == null ? null : deviceArtFor(device, size: 48),
    answers: [
      IslandAnswer(
        l10n.remoteFilesAllowOnce,
        () => answer(FileBrowseDecision.once),
        primary: true,
      ),
      IslandAnswer(l10n.remoteFilesDeny, () => answer(FileBrowseDecision.deny)),
    ],
  );
}

String fileBrowseAskId(String peerId) => 'browse:$peerId';

/// A device asks to pair. Same promise as the dialog this replaces: the answer
/// reaches [resolve] exactly once, and nothing does if the request is cancelled.
void askPairing(
  AppLocalizations l10n,
  PairingRequest request,
  void Function(bool) resolve,
) {
  final id = 'pairing:${request.device.uid}:${request.pairingCode}';
  var answered = false;
  void Function()? stopListening;
  StreamSubscription<void>? cancellation;
  void finish() {
    answered = true;
    stopListening?.call();
    unawaited(cancellation?.cancel());
    RequestIslandSource.shared.settle(id);
  }

  void answer(bool allow) {
    if (answered) return;
    finish();
    resolve(allow);
  }

  final presentation = request.presentation;
  if (presentation != null) {
    stopListening = presentation.addDismissListener(() {
      if (!answered) finish();
    });
  } else if (request.cancellation case final future?) {
    cancellation = future.asStream().listen((_) {
      if (!answered) finish();
    });
  }
  if (answered) return;
  // The same words as the dialog: a changed identity must read as a warning,
  // not as an ordinary request. The digits are what the user compares.
  final name = request.device.name;
  final title = switch (request.reason) {
    PairingReason.newDevice => l10n.pairingNewDeviceTitle,
    PairingReason.identityChanged => l10n.pairingIdentityChangedTitle,
    PairingReason.legacyTrustWithoutPin => l10n.pairingLegacyTrustTitle,
  };
  final why = switch (request.reason) {
    PairingReason.newDevice => l10n.pairingNewDeviceCompareCode(name),
    PairingReason.identityChanged => l10n.pairingIdentityChangedDescription(
      name,
    ),
    PairingReason.legacyTrustWithoutPin => l10n.pairingLegacyTrustDescription(
      name,
    ),
  };
  RequestIslandSource.shared.ask(
    id: id,
    title: title,
    detail: why,
    art: deviceArtFor(request.device, size: 48, paired: false),
    code:
        '${request.pairingCode.substring(0, 3)} '
        '${request.pairingCode.substring(3)}',
    warning: request.reason == PairingReason.identityChanged,
    answers: [
      IslandAnswer(l10n.pairingApprove, () => answer(true), primary: true),
      IslandAnswer(
        request.isInitiator ? l10n.cancel : l10n.pairingReject,
        () => answer(false),
      ),
    ],
  );
}
