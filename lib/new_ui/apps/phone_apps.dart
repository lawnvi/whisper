import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:whisper/new_ui/apps/apps_parts.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// A window open somewhere: 正在流转.
class PhoneAppsFlow {
  const PhoneAppsFlow({
    required this.title,
    required this.detail,
    required this.action,
    required this.onAction,
  });

  final String title, detail, action;
  final VoidCallback onAction;
}

/// One of a device's recent windows.
class PhoneAppsTask {
  const PhoneAppsTask({
    required this.title,
    required this.onTap,
    this.picture,
    this.badge,
    this.closing = false,
    this.onClose,
  });

  final String title;
  final Uint8List? picture;
  final String? badge;
  final bool closing;
  final VoidCallback onTap;
  final VoidCallback? onClose;
}

/// One of a device's apps.
class PhoneAppsEntry {
  const PhoneAppsEntry({
    required this.label,
    required this.hue,
    required this.onTap,
    this.icon,
    this.busy = false,
    this.running = false,
    this.openHere = false,
  });

  final String label;
  final Color hue;
  final Uint8List? icon;
  final bool busy, running, openHere;
  final VoidCallback onTap;
}

/// Why the apps did not come, and trying again.
class PhoneAppsFailure {
  const PhoneAppsFailure({
    required this.title,
    required this.body,
    required this.retry,
    required this.onRetry,
  });

  final String title, body, retry;
  final VoidCallback onRetry;
}

/// surfaces.md「应用」at touch size, `phone-apps.jpg`: what is moving, this
/// device's windows and apps, what can be sent there. It only lays out what
/// it is given; FlowSpacePage knows where it comes from.
class PhoneAppsView extends StatelessWidget {
  const PhoneAppsView({
    super.key,
    required this.movingTitle,
    required this.flows,
    this.appsTitle,
    this.tasks = const [],
    this.apps,
    this.loading = false,
    this.noApps,
    this.notice,
    this.failure,
    this.search,
    this.sendTitle,
    this.send,
    this.closeLabel = '',
  });

  final String movingTitle;
  final List<PhoneAppsFlow> flows;

  /// ‹设备› 上的应用. Without it, the device only receives.
  final String? appsTitle;
  final List<PhoneAppsTask> tasks;
  final List<PhoneAppsEntry>? apps;
  final bool loading;
  final String? noApps;

  /// The device can be seen but something is wrong with it.
  final String? notice;
  final PhoneAppsFailure? failure;

  /// Above the apps, when the other device is a phone.
  final Widget? search;
  final String? sendTitle;
  final Widget? send;
  final String closeLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    final apps = this.apps;
    final sections = <Widget>[
      if (flows.isNotEmpty)
        _Section(
          title: movingTitle,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: c.fill,
              borderRadius: BorderRadius.circular(WhisperRadius.m),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, flow) in flows.indexed) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 12),
                      child: SizedBox(
                        height: 1 / MediaQuery.devicePixelRatioOf(context),
                        child: ColoredBox(color: c.sep),
                      ),
                    ),
                  _FlowRow(flow: flow),
                ],
              ],
            ),
          ),
        ),
      if (appsTitle != null)
        _Section(
          title: appsTitle!,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (search != null) ...[search!, const SizedBox(height: 12)],
              if (notice != null) ...[
                Text(
                  notice!,
                  style: TextStyle(
                    fontSize: type.note,
                    height: 1.4,
                    color: c.warn,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (tasks.isNotEmpty) ...[
                ShellAutoGrid(
                  minWidth: 160,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final task in tasks)
                      ShellWindowThumb(
                        touch: true,
                        title: task.title,
                        picture: task.picture,
                        badge: task.badge,
                        closing: task.closing,
                        onTap: (_) => task.onTap(),
                        onLongPress: task.onClose == null
                            ? null
                            : () => _closeSheet(context, task),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
              ],
              if (failure case final failure?)
                ShellDeviceState(
                  touch: true,
                  art: const SizedBox.shrink(),
                  title: failure.title,
                  body: failure.body,
                  action: PhoneButton(
                    label: failure.retry,
                    kind: PhoneButtonKind.primary,
                    large: true,
                    onTap: failure.onRetry,
                  ),
                )
              else if (loading)
                const Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: CupertinoActivityIndicator()),
                )
              else if (apps != null && apps.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    noApps ?? '',
                    style: TextStyle(fontSize: type.note, color: c.ink2),
                  ),
                )
              else if (apps != null)
                ShellAutoGrid(
                  minWidth: 76,
                  spacing: 6,
                  runSpacing: 12,
                  children: [
                    for (final app in apps)
                      ShellAppIcon(
                        touch: true,
                        label: app.label,
                        hue: app.hue,
                        icon: app.icon,
                        busy: app.busy,
                        running: app.running,
                        openHere: app.openHere,
                        onTap: app.onTap,
                      ),
                  ],
                ),
            ],
          ),
        ),
      if (send != null) _Section(title: sendTitle ?? '', child: send!),
    ];
    return ListView(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        30 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        for (final (i, section) in sections.indexed) ...[
          if (i > 0) const SizedBox(height: 24),
          section,
        ],
      ],
    );
  }

  /// A window can be closed on its device: what a pointer has on the thumbnail.
  void _closeSheet(BuildContext context, PhoneAppsTask task) => unawaited(
    showPhoneSheet<void>(
      context,
      builder: (sheet) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          PhoneSheetTitle(task.title),
          const SizedBox(height: 14),
          ShellGroup(
            children: [
              ShellRow(
                touch: true,
                label: closeLabel,
                color: context.wc.bad,
                onTap: () {
                  Navigator.of(sheet).pop();
                  task.onClose!();
                },
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// `.apps h4` and what is under it.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const type = WhisperType(touch: true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: type.note,
              height: 1.4,
              fontWeight: FontWeight.w600,
              color: context.wc.ink2,
            ),
          ),
        ),
        child,
      ],
    );
  }
}

class _FlowRow extends StatelessWidget {
  const _FlowRow({required this.flow});

  final PhoneAppsFlow flow;

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    const type = WhisperType(touch: true);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    flow.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: type.body,
                      height: 1.3,
                      color: c.ink,
                    ),
                  ),
                  Text(
                    flow.detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: type.note,
                      height: 1.3,
                      color: c.ink2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 140),
              child: PhoneButton(label: flow.action, onTap: flow.onAction),
            ),
          ],
        ),
      ),
    );
  }
}

/// `.sfield` at touch size: 44 high, for the apps of a phone.
