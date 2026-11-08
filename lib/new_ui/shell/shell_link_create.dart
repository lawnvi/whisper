import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:whisper/helper/helper.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/new_ui/phone/phone_parts.dart';
import 'package:whisper/new_ui/shell/shell_parts.dart';
import 'package:whisper/new_ui/shell/shell_share_links.dart';
import 'package:whisper/share_links/share_link_store.dart';
import 'package:whisper/share_links/share_routes.dart';
import 'package:whisper/theme/whisper_ui.dart';

/// `linkCreate`: what to call it, whether to shorten it, a password if wanted.
/// Once made, it shows the link: the code and the address.
Future<ShareLink?> showShellLinkCreate(
  BuildContext context, {
  required List<String> paths,
  required String name,
  ShareLinkStore? store,
}) async {
  final links = store ?? ShareLinkStore.shared;
  Widget builder(BuildContext context) =>
      ShellLinkCreate(store: links, paths: paths, name: name);
  final link = await (isDesktop()
      ? showShellSheet<ShareLink>(context, builder: builder)
      : showPhoneSheet<ShareLink>(context, builder: builder));
  if (link != null && context.mounted) {
    await showShellLinkDetail(context, link, links);
  }
  return link;
}

Future<void> showShellLinkEditor(BuildContext context, WidgetBuilder builder) =>
    isDesktop()
    ? showShellSheet<void>(context, builder: builder)
    : showPhoneSheet<void>(context, builder: builder);

/// A field, and 取消 and 完成 under it.
class _LinkEditor extends StatelessWidget {
  const _LinkEditor({required this.field, required this.onDone});

  final Widget field;
  final VoidCallback? onDone;

  @override
  Widget build(BuildContext context) {
    final l10n = context.shellL10n;
    final touch = !isDesktop();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            ShellButton(
              touch: touch,
              label: l10n.cancel,
              onTap: () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 8),
            ShellButton(
              touch: touch,
              label: l10n.shellDone,
              kind: ShellButtonKind.primary,
              onTap: onDone,
            ),
          ],
        ),
      ],
    );
  }
}

class ShellLinkRouteEditor extends StatefulWidget {
  const ShellLinkRouteEditor({
    super.key,
    required this.store,
    required this.link,
  });

  final ShareLinkStore store;
  final ShareLink link;

  @override
  State<ShellLinkRouteEditor> createState() => _ShellLinkRouteEditorState();
}

class _ShellLinkRouteEditorState extends State<ShellLinkRouteEditor> {
  late final _route = TextEditingController(text: widget.link.route);
  bool _saving = false;
  String? _problem;

  @override
  void dispose() {
    _route.dispose();
    super.dispose();
  }

  String _problemText(AppLocalizations l10n, ShareRouteProblem problem) =>
      switch (problem) {
        ShareRouteProblem.taken => l10n.shareLinkRouteTaken,
        ShareRouteProblem.reserved => l10n.shareLinkRouteReserved,
        ShareRouteProblem.invalid => l10n.shareLinkRouteInvalid,
      };

  /// A route another link has is said as it is typed. One that is merely too
  /// short so far waits until 完成.
  void _changed(AppLocalizations l10n) {
    final typed = ShareRoutes.normalize(_route.text);
    var problem = typed.isEmpty ? null : ShareRoutes.check(typed);
    if (problem == ShareRouteProblem.invalid) problem = null;
    if (problem == null &&
        widget.store.links.any(
          (other) => other.route == typed && other.id != widget.link.id,
        )) {
      problem = ShareRouteProblem.taken;
    }
    setState(() {
      _problem = problem == null ? null : _problemText(l10n, problem);
    });
  }

  Future<void> _save(AppLocalizations l10n) async {
    setState(() {
      _saving = true;
      _problem = null;
    });
    String? failure;
    try {
      await widget.store.setRoute(widget.link.id, _route.text);
    } on ShareRouteException catch (error) {
      failure = _problemText(l10n, error.problem);
    } on Object {
      failure = l10n.shareLinkCreateFailed;
    }
    if (!mounted) return;
    if (failure != null) {
      setState(() {
        _saving = false;
        _problem = failure;
      });
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.shellL10n;
    return _LinkEditor(
      onDone: _saving ? null : () => unawaited(_save(l10n)),
      field: ShellField(
        label: l10n.shareLinkRoute,
        controller: _route,
        touch: !isDesktop(),
        error: _problem,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_\-]')),
          LengthLimitingTextInputFormatter(ShareRoutes.maxLength),
        ],
        onChanged: (_) => _changed(l10n),
      ),
    );
  }
}

class ShellLinkPasswordEditor extends StatefulWidget {
  const ShellLinkPasswordEditor({
    super.key,
    required this.store,
    required this.link,
  });

  final ShareLinkStore store;
  final ShareLink link;

  @override
  State<ShellLinkPasswordEditor> createState() =>
      _ShellLinkPasswordEditorState();
}

class _ShellLinkPasswordEditorState extends State<ShellLinkPasswordEditor> {
  final _password = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.store.setPassword(widget.link.id, _password.text);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => _LinkEditor(
    onDone: _saving ? null : () => unawaited(_save()),
    field: ShellField(
      label: context.shellL10n.shellLinkPasswordOptional,
      controller: _password,
      obscure: true,
      showLabel: context.shellL10n.shareLinkShowPassword,
      hideLabel: context.shellL10n.shareLinkHidePassword,
      touch: !isDesktop(),
    ),
  );
}

class ShellLinkCreate extends StatefulWidget {
  const ShellLinkCreate({
    super.key,
    required this.store,
    required this.paths,
    required this.name,
  });

  final ShareLinkStore store;
  final List<String> paths;
  final String name;

  @override
  State<ShellLinkCreate> createState() => _ShellLinkCreateState();
}

class _ShellLinkCreateState extends State<ShellLinkCreate> {
  final _route = TextEditingController();
  final _password = TextEditingController();
  late String _suggested = widget.store.suggestRoute();
  bool _short = false;
  bool _creating = false;
  String? _problem;

  @override
  void initState() {
    super.initState();
    unawaited(widget.store.initialize());
  }

  @override
  void dispose() {
    _route.dispose();
    _password.dispose();
    super.dispose();
  }

  String _routeProblemText(AppLocalizations l10n, ShareRouteProblem problem) =>
      switch (problem) {
        ShareRouteProblem.taken => l10n.shareLinkRouteTaken,
        ShareRouteProblem.reserved => l10n.shareLinkRouteReserved,
        ShareRouteProblem.invalid => l10n.shareLinkRouteInvalid,
      };

  /// A route another link has is said as it is typed. One that is merely too
  /// short so far waits until 创建链接.
  void _routeChanged(AppLocalizations l10n) {
    final typed = ShareRoutes.normalize(_route.text);
    var problem = typed.isEmpty ? null : ShareRoutes.check(typed);
    if (problem == ShareRouteProblem.invalid) problem = null;
    if (problem == null && widget.store.links.any((l) => l.route == typed)) {
      problem = ShareRouteProblem.taken;
    }
    setState(() {
      _problem = problem == null ? null : _routeProblemText(l10n, problem);
    });
  }

  Future<void> _create(AppLocalizations l10n) async {
    if (_creating) return;
    final typed = ShareRoutes.normalize(_route.text);
    if (typed.isNotEmpty) {
      final problem = ShareRoutes.check(typed);
      if (problem != null) {
        setState(() => _problem = _routeProblemText(l10n, problem));
        return;
      }
    }
    setState(() {
      _creating = true;
      _problem = null;
    });
    ShareLink? link;
    String? failure;
    // A suggestion can be taken meanwhile: then it takes another.
    for (
      var attempt = 0;
      attempt < 3 && link == null && failure == null;
      attempt++
    ) {
      try {
        link = await widget.store.create(
          paths: widget.paths,
          route: typed.isEmpty ? _suggested : typed,
          short: _short,
          password: _password.text.isEmpty ? null : _password.text,
        );
      } on ShareRouteException catch (error) {
        if (typed.isEmpty && error.problem == ShareRouteProblem.taken) {
          _suggested = widget.store.suggestRoute(short: _short);
        } else {
          failure = _routeProblemText(l10n, error.problem);
        }
      } on ShareLinkException {
        failure = l10n.shareLinkItemsMissing;
      } on Object {
        failure = l10n.shareLinkCreateFailed;
      }
    }
    if (!mounted) return;
    if (link == null) {
      setState(() {
        _creating = false;
        _problem = failure ?? l10n.shareLinkCreateFailed;
      });
      return;
    }
    Navigator.of(context).pop(link);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.wc;
    final l10n = context.shellL10n;
    final touch = !isDesktop();
    final type = WhisperType(touch: touch);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.shellLinkCreateTitle(widget.name),
          style: TextStyle(
            fontSize: type.head,
            fontWeight: FontWeight.w600,
            color: c.ink,
          ),
        ),
        const SizedBox(height: 14),
        ShellField(
          label: l10n.shareLinkRoute,
          controller: _route,
          hint: _suggested,
          touch: touch,
          error: _problem,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_\-]')),
            LengthLimitingTextInputFormatter(ShareRoutes.maxLength),
          ],
          onChanged: (_) => _routeChanged(l10n),
        ),
        const SizedBox(height: 14),
        ConstrainedBox(
          constraints: BoxConstraints(minHeight: touch ? 48 : 28),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.shareLinkShortRoute,
                  style: TextStyle(fontSize: type.body, color: c.ink),
                ),
              ),
              ShellSwitch(
                touch: touch,
                label: l10n.shareLinkShortRoute,
                value: _short,
                onChanged: (value) => setState(() {
                  _short = value;
                  _suggested = widget.store.suggestRoute(short: value);
                }),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        ShellField(
          label: l10n.shellLinkPasswordOptional,
          controller: _password,
          obscure: true,
          showLabel: l10n.shareLinkShowPassword,
          hideLabel: l10n.shareLinkHidePassword,
          touch: touch,
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            ShellButton(
              touch: touch,
              label: l10n.cancel,
              onTap: () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 8),
            ShellButton(
              touch: touch,
              label: l10n.shareLinkCreate,
              kind: ShellButtonKind.primary,
              onTap: _creating ? null : () => unawaited(_create(l10n)),
            ),
          ],
        ),
      ],
    );
  }
}
