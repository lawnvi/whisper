import 'package:whisper/helper/toast.dart';
import 'package:whisper/helper/wake_on_lan.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/model/LocalDatabase.dart';

/// Whether [device] said which cards can wake it, so it can be woken while
/// it is asleep.
bool canWake(DeviceData device) => WakeTargets.shared.of(device.uid).isNotEmpty;

/// Wakes those of [devices] that can be woken, and says so on the island (a
/// toast on a phone). Connecting again is left to auto-connect once they are
/// back on the network.
Future<void> wakeDevices(Iterable<DeviceData> devices) async {
  await WakeTargets.shared.load();
  final woken = <String>[];
  for (final device in devices) {
    final targets = WakeTargets.shared.of(device.uid);
    if (targets.isEmpty) continue;
    if (await sendWakePackets(targets, lastHost: device.host)) {
      woken.add(device.label);
    }
  }
  final context = appNavigatorKey.currentContext;
  if (woken.isEmpty || context == null || !context.mounted) return;
  final l10n = AppLocalizations.of(context);
  if (l10n != null) showAppToast(l10n.wakeSent(woken.join(', ')));
}
