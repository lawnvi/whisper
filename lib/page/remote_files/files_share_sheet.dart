import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../helper/helper.dart' show copyToClipboard;
import '../../l10n/app_localizations.dart';
import '../../helper/toast.dart';
import '../../helper/transfer_notification_aggregator.dart'
    show formatBytesForNotification;
import '../../remote_files/fs_browser.dart' show LocalFsBrowser;
import '../../remote_files/fs_host_files.dart' show FsEntry;
import '../../share_links/share_link_store.dart';
import '../../share_links/share_names.dart';
import '../../share_links/share_routes.dart';
import '../window_stream/flow_space_theme.dart';
import 'files_confirm.dart';
import 'files_icons.dart';
import 'files_model.dart';

/// Something on this device to give out through a share link.
class ShareSource {
  const ShareSource({
    required this.absolutePath,
    required this.name,
    required this.isDir,
  });

  final String absolutePath;
  final String name;
  final bool isDir;
}

/// Asks how to share [items] (route, short route, password), makes the
/// link and then shows it: address, QR code, copy. A card in the middle
/// on wide windows, a sheet from the bottom on phones. The link, or null
/// when nothing was made.
Future<ShareLink?> showShareLinkSheet(
  BuildContext context, {
  required List<ShareSource> items,
  ShareLinkStore? store,
}) async {
  if (items.isEmpty) {
    return null;
  }
  final created = ValueNotifier<ShareLink?>(null);
  final result = await _push(
    context,
    (wide) => _ShareSheet(
      store: store ?? ShareLinkStore.shared,
      items: items,
      wide: wide,
      created: created,
    ),
  );
  final link = result ?? created.value;
  created.dispose();
  return link;
}

/// An existing link: address, QR code, copy and delete.
Future<void> showShareLinkDetails(
  BuildContext context,
  ShareLink link, {
  ShareLinkStore? store,
}) => _push(
  context,
  (wide) => _ShareSheet(
    store: store ?? ShareLinkStore.shared,
    link: link,
    wide: wide,
  ),
);

/// The file manager's way in: [items] on this device (its own paths are
/// relative to a root) become a share link.
Future<ShareLink?> shareFilesItems(
  BuildContext context,
  FilesController controller,
  List<FilesItem> items,
) async {
  final browser = controller.deviceById(FilesDevice.localId)?.browser;
  if (browser is! LocalFsBrowser || items.isEmpty) {
    return null;
  }
  final text = AppLocalizations.of(context)!;
  final sources = <ShareSource>[];
  for (final item in items) {
    if (item.location.deviceId != FilesDevice.localId) {
      continue;
    }
    try {
      sources.add(
        ShareSource(
          absolutePath: await browser.realPath(item.location.root, item.path),
          name: item.name,
          isDir: item.isDir,
        ),
      );
    } on Object {
      // Gone since it was listed; the rest can still be shared.
    }
  }
  if (sources.isEmpty) {
    showAppToast(text.shareLinkItemsMissing, tone: AppToastTone.error);
    return null;
  }
  if (!context.mounted) {
    return null;
  }
  return showShareLinkSheet(context, items: sources);
}

Future<ShareLink?> _push(
  BuildContext context,
  Widget Function(bool wide) builder,
) {
  HapticFeedback.selectionClick();
  final wide = MediaQuery.sizeOf(context).width >= 700;
  return Navigator.of(context).push<ShareLink>(
    _SheetRoute(
      wide: wide,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      builder: (_) => builder(wide),
    ),
  );
}

class _SheetRoute extends PopupRoute<ShareLink> {
  _SheetRoute({
    required this.wide,
    required this.builder,
    required this.barrierLabel,
  });

  final bool wide;
  final WidgetBuilder builder;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => Colors.black.withValues(alpha: 0.32);

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 460);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => builder(context);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (flowReduceMotion(context)) {
      return FadeTransition(opacity: animation, child: child);
    }
    final motion = CurvedAnimation(
      parent: animation,
      curve: const SpringCurve(FlowSpaceTokens.snappySpring, 0.46),
      reverseCurve: Curves.easeInCubic,
    );
    final fade = CurvedAnimation(
      parent: animation,
      curve: const Interval(0, 0.4, curve: Curves.easeOut),
      reverseCurve: Curves.easeIn,
    );
    return AnimatedBuilder(
      animation: motion,
      child: child,
      builder: (context, child) {
        final t = motion.value;
        return FadeTransition(
          opacity: fade,
          child: wide
              ? Transform.scale(scale: 0.9 + 0.1 * t, child: child)
              : FractionalTranslation(
                  translation: Offset(0, (1 - t) * 0.6),
                  child: child,
                ),
        );
      },
    );
  }
}

/// The sheet's own grey and the groups on it, as in iOS grouped lists.
Color _sheetColor(FlowSpaceColors colors) =>
    colors.dark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);

Color _groupColor(FlowSpaceColors colors) =>
    colors.dark ? const Color(0xFF2C2C2E) : Colors.white;

Color _accent(FlowSpaceColors colors) =>
    colors.dark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);

const _red = Color(0xFFFF3B30);
const _green = Color(0xFF34C759);

const _mono = TextStyle(
  fontFamily: 'Menlo',
  fontFamilyFallback: [
    'SF Mono',
    'Consolas',
    'Cascadia Mono',
    'Roboto Mono',
    'DejaVu Sans Mono',
    'Noto Sans Mono',
    'monospace',
  ],
);

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({
    required this.store,
    required this.wide,
    this.items,
    this.link,
    this.created,
  });

  final ShareLinkStore store;
  final bool wide;

  /// What to share (making a link) …
  final List<ShareSource>? items;

  /// … or the link to show.
  final ShareLink? link;
  final ValueNotifier<ShareLink?>? created;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  final _route = TextEditingController();
  final _password = TextEditingController();
  final _routeFocus = FocusNode(debugLabel: 'share-route');
  final _passwordFocus = FocusNode(debugLabel: 'share-password');
  late String _placeholder;
  bool _short = false;
  bool _showPassword = false;
  bool _creating = false;
  bool _tried = false;
  ShareRouteProblem? _routeProblem;
  String? _failure;
  ShareLink? _link;
  String? _address;
  bool _copied = false;
  Timer? _copiedTimer;

  ShareLinkStore get store => widget.store;
  bool get _details => widget.link != null;

  @override
  void initState() {
    super.initState();
    _link = widget.link;
    _placeholder = store.suggestRoute();
    _route.addListener(_onRouteChanged);
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    await store.initialize();
    await store.refreshAddresses();
    if (!mounted) {
      return;
    }
    // Now that the saved links are known, make sure the suggestion is free.
    if (store.links.any((link) => link.route == _placeholder)) {
      setState(() => _placeholder = store.suggestRoute(short: _short));
    }
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    _route.dispose();
    _password.dispose();
    _routeFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _onRouteChanged() {
    final typed = _route.text;
    ShareRouteProblem? problem;
    if (typed.isNotEmpty) {
      problem = ShareRoutes.check(typed);
      if (problem == ShareRouteProblem.invalid && !_tried) {
        // Too short while still typing is not worth a red line yet.
        problem = null;
      }
      if (problem == null && store.links.any((link) => link.route == typed)) {
        problem = ShareRouteProblem.taken;
      }
    }
    // Rebuilds the preview line under the group as well.
    setState(() {
      _routeProblem = problem;
      _failure = null;
    });
  }

  Future<void> _create() async {
    final items = widget.items;
    if (_creating || items == null) {
      return;
    }
    _tried = true;
    final typed = _route.text.trim();
    if (typed.isNotEmpty) {
      final problem = ShareRoutes.check(typed);
      if (problem != null) {
        setState(() => _routeProblem = problem);
        _routeFocus.requestFocus();
        return;
      }
    }
    final text = AppLocalizations.of(context)!;
    setState(() {
      _creating = true;
      _failure = null;
    });
    ShareLink? link;
    for (var attempt = 0; attempt < 3 && link == null; attempt++) {
      try {
        link = await store.create(
          paths: [for (final item in items) item.absolutePath],
          route: typed.isEmpty ? _placeholder : typed,
          short: _short,
          password: _password.text.isEmpty ? null : _password.text,
        );
      } on ShareRouteException catch (error) {
        if (typed.isEmpty && error.problem == ShareRouteProblem.taken) {
          // The suggestion went to another link meanwhile; take a new one.
          _placeholder = store.suggestRoute(short: _short);
          continue;
        }
        if (!mounted) {
          return;
        }
        setState(() {
          _creating = false;
          _routeProblem = error.problem;
        });
        _routeFocus.requestFocus();
        return;
      } on ShareLinkException {
        if (mounted) {
          setState(() {
            _creating = false;
            _failure = text.shareLinkItemsMissing;
          });
        }
        return;
      } on Object {
        if (mounted) {
          setState(() {
            _creating = false;
            _failure = text.shareLinkCreateFailed;
          });
        }
        return;
      }
    }
    if (!mounted) {
      return;
    }
    if (link == null) {
      setState(() {
        _creating = false;
        _failure = text.shareLinkCreateFailed;
      });
      return;
    }
    HapticFeedback.lightImpact();
    widget.created?.value = link;
    FocusScope.of(context).unfocus();
    setState(() {
      _creating = false;
      _link = link;
    });
  }

  Future<void> _copy(String url) async {
    HapticFeedback.selectionClick();
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) {
        setState(() => _copied = false);
      }
    });
    // Kept out of clipboard sync: the address is for someone without
    // Whisper, not for the paired devices.
    await copyToClipboard(
      url,
      suppressWatcher: true,
      sourcePeerId: 'share-link',
    );
  }

  Future<void> _delete(ShareLink link) async {
    final text = AppLocalizations.of(context)!;
    final confirmed = await showFilesConfirm(
      context,
      title: text.shareLinkDeleteTitle,
      detail: text.shareLinkDeleteDetail,
      confirmLabel: text.delete,
      names: [shareLinkTitle(text, link)],
      icon: CupertinoIcons.link,
    );
    if (!confirmed) {
      return;
    }
    await store.remove(link.id);
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _close() {
    HapticFeedback.selectionClick();
    Navigator.of(context).pop(_link);
  }

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final media = MediaQuery.of(context);
    final link = _link;
    final body = ListenableBuilder(
      listenable: store,
      builder: (context, _) => AnimatedSwitcher(
        duration: flowReduceMotion(context)
            ? Duration.zero
            : const Duration(milliseconds: 280),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: [...previous, ?current],
        ),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween(begin: 0.97, end: 1.0).animate(animation),
            child: child,
          ),
        ),
        child: link == null
            ? KeyedSubtree(
                key: const ValueKey('create'),
                child: _buildCreate(context, colors),
              )
            : _details
            ? KeyedSubtree(
                key: const ValueKey('details'),
                child: _buildDetails(context, colors, link),
              )
            : KeyedSubtree(
                key: const ValueKey('result'),
                child: _buildResult(context, colors, link),
              ),
      ),
    );
    final radius = BorderRadius.circular(widget.wide ? 26 : 30);
    final card = Material(
      type: MaterialType.transparency,
      child: Container(
        width: widget.wide ? (_details ? 760 : 440) : double.infinity,
        constraints: BoxConstraints(
          maxHeight: media.size.height - media.viewInsets.bottom - 32,
        ),
        decoration: ShapeDecoration(
          color: _sheetColor(colors),
          shape: RoundedSuperellipseBorder(
            borderRadius: radius,
            side: BorderSide(color: colors.hairline, width: 0.5),
          ),
          shadows: [
            BoxShadow(
              color: Colors.black.withValues(alpha: colors.dark ? 0.5 : 0.2),
              blurRadius: 44,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
            child: AnimatedSize(
              duration: flowReduceMotion(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: body,
            ),
          ),
        ),
      ),
    );
    final shortcuts = CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): _close},
      child: FocusScope(autofocus: true, child: card),
    );
    if (widget.wide) {
      return Center(child: shortcuts);
    }
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          8,
          0,
          8,
          math.max(8, media.padding.bottom + 4) + media.viewInsets.bottom,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: shortcuts,
        ),
      ),
    );
  }

  Widget _buildCreate(BuildContext context, FlowSpaceColors colors) {
    final text = AppLocalizations.of(context)!;
    final accent = _accent(colors);
    final items = widget.items ?? const <ShareSource>[];
    final typed = _route.text.trim();
    final route = typed.isEmpty ? _placeholder : typed;
    final address = _address ?? store.addresses.firstOrNull;
    final preview = 'http://${address ?? '…'}:${store.port}/$route';
    final problem = _routeProblem;
    final cancel = _SheetButton(
      label: text.cancel,
      color: _groupColor(colors),
      textColor: colors.label,
      onPressed: _creating ? null : () => Navigator.of(context).pop(),
    );
    final create = _SheetButton(
      label: text.shareLinkCreate,
      color: accent,
      textColor: Colors.white,
      busy: _creating,
      autofocus: widget.wide,
      onPressed: problem == null ? _create : null,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Badge(icon: CupertinoIcons.link, color: accent),
        const SizedBox(height: 12),
        _Title(text.shareLinkCreateTitle),
        const SizedBox(height: 5),
        _Lead(text.shareLinkCreateDetail),
        const SizedBox(height: 18),
        _ItemsSummary(items: items),
        const SizedBox(height: 18),
        _FormGroup(
          children: [
            _FieldRow(
              label: text.shareLinkRoute,
              child: _InlineField(
                controller: _route,
                focusNode: _routeFocus,
                placeholder: _placeholder,
                prefix: '/',
                mono: true,
                error: problem != null,
                enabled: !_creating,
                formatters: [
                  _LowerCase(),
                  FilteringTextInputFormatter.allow(RegExp(r'[a-z0-9_-]')),
                  LengthLimitingTextInputFormatter(ShareRoutes.maxLength),
                ],
                onSubmitted: (_) => _passwordFocus.requestFocus(),
              ),
            ),
            _SwitchRow(
              title: text.shareLinkShortRoute,
              detail: text.shareLinkShortRouteDetail,
              value: _short,
              onChanged: _creating
                  ? null
                  : (value) => setState(() {
                      _short = value;
                      _placeholder = store.suggestRoute(short: value);
                    }),
            ),
            _FieldRow(
              label: text.shareLinkPassword,
              child: _InlineField(
                controller: _password,
                focusNode: _passwordFocus,
                placeholder: text.shareLinkPasswordOptional,
                obscure: !_showPassword,
                enabled: !_creating,
                onSubmitted: (_) => unawaited(_create()),
                suffix: _IconToggle(
                  icon: _showPassword
                      ? CupertinoIcons.eye_slash
                      : CupertinoIcons.eye,
                  tooltip: _showPassword
                      ? text.shareLinkHidePassword
                      : text.shareLinkShowPassword,
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 7, 16, 0),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 160),
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topLeft,
              children: [...previous, ?current],
            ),
            child: problem != null
                ? Text(
                    key: ValueKey(problem),
                    switch (problem) {
                      ShareRouteProblem.invalid => text.shareLinkRouteInvalid,
                      ShareRouteProblem.reserved => text.shareLinkRouteReserved,
                      ShareRouteProblem.taken => text.shareLinkRouteTaken,
                    },
                    style: const TextStyle(color: _red, fontSize: 12.5),
                  )
                : Column(
                    key: const ValueKey('preview'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (typed.isEmpty)
                        Text(
                          text.shareLinkRouteHelp,
                          style: TextStyle(
                            color: colors.secondaryLabel,
                            fontSize: 12.5,
                          ),
                        ),
                      Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: _mono.copyWith(
                          color: colors.secondaryLabel,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        if (_failure != null) ...[
          const SizedBox(height: 12),
          Text(
            _failure!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _red, fontSize: 13),
          ),
        ],
        const SizedBox(height: 20),
        if (widget.wide)
          Row(
            children: [
              Expanded(child: cancel),
              const SizedBox(width: 10),
              Expanded(child: create),
            ],
          )
        else ...[
          create,
          const SizedBox(height: 8),
          cancel,
        ],
      ],
    );
  }

  /// Right after making the link: everything needed to hand it on.
  Widget _buildResult(
    BuildContext context,
    FlowSpaceColors colors,
    ShareLink link,
  ) {
    final text = AppLocalizations.of(context)!;
    final url = store.urlFor(link, _currentAddress());
    final copy = _copyButton(text, colors, url);
    final done = _SheetButton(
      label: text.remoteFilesDone,
      color: _groupColor(colors),
      textColor: colors.label,
      autofocus: true,
      onPressed: _close,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Badge(icon: CupertinoIcons.checkmark_alt, color: _green),
        const SizedBox(height: 12),
        _Title(text.shareLinkReady),
        if (link.hasPassword) ...[
          const SizedBox(height: 7),
          Center(child: _PasswordBadge(text: text)),
        ],
        const SizedBox(height: 18),
        _ShareCard(
          url: url,
          route: link.route,
          caption: text.shareLinkScanHint,
          addresses: store.addresses,
          selected: _currentAddress(),
          tooltip: text.shareLinkAddressPicker,
          onAddress: (value) => setState(() => _address = value),
        ),
        ..._notes(context, colors, link),
        const SizedBox(height: 18),
        if (widget.wide)
          Row(
            children: [
              Expanded(child: done),
              const SizedBox(width: 10),
              Expanded(child: copy),
            ],
          )
        else ...[
          copy,
          const SizedBox(height: 8),
          done,
        ],
      ],
    );
  }

  /// An existing link: hand it on, turn it on or off, see how it is used,
  /// delete it. Laid out like an iOS settings page.
  Widget _buildDetails(
    BuildContext context,
    FlowSpaceColors colors,
    ShareLink link,
  ) {
    final text = AppLocalizations.of(context)!;
    final url = store.urlFor(link, _currentAddress());
    final last = link.lastVisitAt;
    final share = <Widget>[
      _ShareCard(
        url: url,
        route: link.route,
        caption: text.shareLinkScanHint,
        addresses: store.addresses,
        selected: _currentAddress(),
        tooltip: text.shareLinkAddressPicker,
        onAddress: (value) => setState(() => _address = value),
        dimmed: !link.enabled,
      ),
      const SizedBox(height: 12),
      _copyButton(text, colors, url),
      ..._notes(context, colors, link),
    ];
    final settings = <Widget>[
      _FormGroup(
        children: [
          _SwitchRow(
            title: text.shareLinkAllowAccess,
            value: link.enabled,
            onChanged: (value) => unawaited(store.setEnabled(link.id, value)),
          ),
        ],
      ),
      const SizedBox(height: 20),
      _FormGroup(
        children: [
          _ValueRow(label: text.shareLinkVisitsLabel, value: '${link.visits}'),
          _ValueRow(
            label: text.shareLinkDownloadsLabel,
            value: '${link.downloads}',
          ),
          _ValueRow(
            label: text.shareLinkSentLabel,
            value: formatBytesForNotification(link.bytesServed),
          ),
          _ValueRow(
            label: text.shareLinkLastVisitLabel,
            value: last == null
                ? text.shareLinkNever
                : fsDateLabel(context, last.millisecondsSinceEpoch),
          ),
        ],
      ),
      const SizedBox(height: 20),
      _FormGroup(
        children: [
          _ActionRow(
            label: text.shareLinkDelete,
            color: _red,
            onTap: () => unawaited(_delete(link)),
          ),
        ],
      ),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(width: 40, height: 40, child: _ItemIcon(link: link)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    shareLinkTitle(text, link),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.label,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.3,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        '/${link.route}',
                        style: _mono.copyWith(
                          color: colors.secondaryLabel,
                          fontSize: 12.5,
                        ),
                      ),
                      if (link.hasPassword) ...[
                        const SizedBox(width: 8),
                        _PasswordBadge(text: text),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            CupertinoButton(
              padding: const EdgeInsets.only(left: 12),
              minimumSize: const Size(0, 36),
              onPressed: _close,
              child: Text(
                text.remoteFilesDone,
                style: TextStyle(
                  color: _accent(colors),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Wide windows: the link on the left, its settings on the right,
        // so nothing has to scroll. Phones: one column.
        if (widget.wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: share,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 11,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: settings,
                ),
              ),
            ],
          )
        else ...[
          ...share,
          const SizedBox(height: 20),
          ...settings,
        ],
      ],
    );
  }

  String? _currentAddress() {
    final addresses = store.addresses;
    final chosen = _address;
    if (chosen != null && addresses.contains(chosen)) {
      return chosen;
    }
    return addresses.firstOrNull;
  }

  Widget _copyButton(
    AppLocalizations text,
    FlowSpaceColors colors,
    String url,
  ) {
    final accent = _accent(colors);
    return _SheetButton(
      label: _copied ? text.shareLinkCopied : text.shareLinkCopy,
      icon: _copied ? CupertinoIcons.checkmark_alt : CupertinoIcons.doc_on_doc,
      color: _copied ? _green : accent,
      textColor: Colors.white,
      onPressed: () => unawaited(_copy(url)),
    );
  }

  /// What keeps the link from opening right now, if anything.
  List<Widget> _notes(
    BuildContext context,
    FlowSpaceColors colors,
    ShareLink link,
  ) {
    final text = AppLocalizations.of(context)!;
    final state = store.serverState;
    final availability = store.availabilityOf(link);
    final notes = <Widget>[
      if (!store.serviceOn)
        _Note(
          icon: CupertinoIcons.pause_circle_fill,
          color: const Color(0xFFFF9500),
          text: text.shareLinkServiceOffNote,
          trailing: CupertinoSwitch(
            value: false,
            activeTrackColor: _green,
            onChanged: (value) => unawaited(store.setServiceOn(value)),
          ),
        )
      else if (state.phase == ShareServerPhase.failed)
        _Note(
          icon: CupertinoIcons.exclamationmark_triangle_fill,
          color: _red,
          text: shareServerFailureText(text, store),
          trailing: CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 30),
            onPressed: () => unawaited(store.retry()),
            child: Text(
              text.retry,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      if (store.addresses.isEmpty)
        _Note(
          icon: CupertinoIcons.wifi_slash,
          color: const Color(0xFFFF9500),
          text: text.shareLinkNoNetwork,
        ),
      if (availability != ShareAvailability.available)
        _Note(
          icon: CupertinoIcons.exclamationmark_circle_fill,
          color: const Color(0xFFFF9500),
          text: availability == ShareAvailability.missing
              ? text.shareLinkStatusMissing
              : text.shareLinkStatusPartlyMissing,
        ),
    ];
    return [
      for (final note in notes) ...[const SizedBox(height: 10), note],
    ];
  }
}

/// "3 次访问 · 1 次下载 · 最近访问 今天 10:24 · 已发送 1.2 GB".
String shareLinkStats(
  BuildContext context,
  AppLocalizations text,
  ShareLink link,
) {
  final last = link.lastVisitAt;
  return [
    text.shareLinkVisits(link.visits),
    text.shareLinkDownloads(link.downloads),
    if (link.bytesServed > 0)
      text.shareLinkBytesServed(formatBytesForNotification(link.bytesServed)),
    if (last == null)
      text.shareLinkNeverVisited
    else
      text.shareLinkLastVisit(
        fsDateLabel(context, last.millisecondsSinceEpoch),
      ),
  ].join(' · ');
}

/// Why the file server is not running, for a failed start.
String shareServerFailureText(AppLocalizations text, ShareLinkStore store) {
  final state = store.serverState;
  if (state.failure == ShareServerFailure.portsBusy) {
    final ports = state.ports ?? const <int>[];
    final (from, to) = ports.isEmpty
        ? store.portRange
        : (ports.reduce(math.min), ports.reduce(math.max));
    return text.shareLinksServicePortsBusy('$from', '$to');
  }
  return text.shareLinksServiceFailed;
}

class _Title extends StatelessWidget {
  const _Title(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        color: FlowSpaceColors.of(context).label,
        fontSize: 19,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
      ),
    );
  }
}

class _Lead extends StatelessWidget {
  const _Lead(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: FlowSpaceColors.of(context).secondaryLabel,
          fontSize: 13.5,
          height: 1.4,
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 56,
        height: 56,
        decoration: ShapeDecoration(
          color: color,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          shadows: [
            BoxShadow(
              color: color.withValues(alpha: 0.3),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 28, color: Colors.white),
      ),
    );
  }
}

class _PasswordBadge extends StatelessWidget {
  const _PasswordBadge({required this.text});

  final AppLocalizations text;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
      decoration: ShapeDecoration(
        color: colors.dark
            ? Colors.white.withValues(alpha: 0.1)
            : Colors.black.withValues(alpha: 0.06),
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            CupertinoIcons.lock_fill,
            size: 10.5,
            color: colors.secondaryLabel,
          ),
          const SizedBox(width: 4),
          Text(
            text.shareLinkPasswordProtected,
            style: TextStyle(color: colors.secondaryLabel, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

/// The link's item icon (one item) or a stack (several).
class _ItemIcon extends StatelessWidget {
  const _ItemIcon({required this.link});

  final ShareLink link;

  @override
  Widget build(BuildContext context) {
    final first = link.items.first;
    if (link.items.length == 1) {
      return FsFileIcon(
        entry: FsEntry(
          name: first.name,
          isDir: first.isDir,
          size: 0,
          modifiedMs: 0,
        ),
        size: 40,
      );
    }
    return Container(
      decoration: ShapeDecoration(
        color: const Color(0xFF5856D6),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
      alignment: Alignment.center,
      child: const Icon(
        CupertinoIcons.square_stack_3d_up_fill,
        size: 22,
        color: Colors.white,
      ),
    );
  }
}

/// What is being shared: the first few with their icons, then a count.
class _ItemsSummary extends StatelessWidget {
  const _ItemsSummary({required this.items});

  final List<ShareSource> items;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final text = AppLocalizations.of(context)!;
    final shown = items.take(3).toList();
    final more = items.length - shown.length;
    return _FormGroup(
      children: [
        for (final item in shown)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
            child: Row(
              children: [
                FsFileIcon(
                  entry: FsEntry(
                    name: item.name,
                    isDir: item.isDir,
                    size: 0,
                    modifiedMs: 0,
                  ),
                  size: 26,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: colors.label, fontSize: 14.5),
                  ),
                ),
              ],
            ),
          ),
        if (more > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(52, 10, 14, 10),
            child: Text(
              text.remoteFilesAndMore(more),
              style: TextStyle(color: colors.secondaryLabel, fontSize: 13.5),
            ),
          ),
      ],
    );
  }
}

/// A rounded group of rows with inset hairlines between them.
class _FormGroup extends StatelessWidget {
  const _FormGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 14),
            child: Container(height: 0.5, color: colors.hairline),
          ),
        );
      }
      rows.add(children[i]);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: _groupColor(colors),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        ),
      ),
    );
  }
}

/// A label on the left, a field filling the rest of the row.
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 46),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 14),
            // One width for every label, so the fields line up.
            child: SizedBox(
              width: 96,
              child: Text(
                label,
                maxLines: 2,
                style: TextStyle(color: colors.label, fontSize: 15.5),
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// A borderless text field for a [_FieldRow].
class _InlineField extends StatelessWidget {
  const _InlineField({
    required this.controller,
    required this.focusNode,
    required this.placeholder,
    this.error = false,
    this.mono = false,
    this.obscure = false,
    this.enabled = true,
    this.prefix,
    this.suffix,
    this.formatters,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String placeholder;
  final bool error;
  final bool mono;
  final bool obscure;
  final bool enabled;
  final String? prefix;
  final Widget? suffix;
  final List<TextInputFormatter>? formatters;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final style = TextStyle(
      color: error ? _red : colors.label,
      fontSize: 15.5,
    ).merge(mono ? _mono : null);
    return CupertinoTextField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      textCapitalization: TextCapitalization.none,
      keyboardType: obscure ? TextInputType.visiblePassword : TextInputType.url,
      inputFormatters: formatters,
      placeholder: placeholder,
      placeholderStyle: style.copyWith(color: colors.tertiaryLabel),
      style: style,
      cursorColor: _accent(colors),
      decoration: null,
      padding: EdgeInsets.fromLTRB(
        prefix == null ? 8 : 2,
        12,
        suffix == null ? 14 : 4,
        12,
      ),
      prefix: prefix == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(
                prefix!,
                style: style.copyWith(color: colors.tertiaryLabel),
              ),
            ),
      suffix: suffix,
      onSubmitted: onSubmitted,
    );
  }
}

class _LowerCase extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => newValue.copyWith(text: newValue.text.toLowerCase());
}

class _IconToggle extends StatelessWidget {
  const _IconToggle({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(40, 40),
        onPressed: onPressed,
        child: Icon(
          icon,
          size: 18,
          color: FlowSpaceColors.of(context).secondaryLabel,
        ),
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.value,
    required this.onChanged,
    this.detail,
  });

  final String title;
  final String? detail;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return MergeSemantics(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onChanged == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onChanged!(!value);
              },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 30),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        title,
                        style: TextStyle(color: colors.label, fontSize: 15.5),
                      ),
                      if (detail != null) ...[
                        const SizedBox(height: 1),
                        Text(
                          detail!,
                          style: TextStyle(
                            color: colors.secondaryLabel,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                CupertinoSwitch(
                  value: value,
                  activeTrackColor: _green,
                  onChanged: onChanged,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A label and its value, grey on the right.
class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Text(label, style: TextStyle(color: colors.label, fontSize: 15.5)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.end,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.secondaryLabel,
                  fontSize: 15.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A whole row that is one action, centred (iOS "Delete" rows).
class _ActionRow extends StatefulWidget {
  const _ActionRow({
    required this.label,
    required this.color,
    required this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  State<_ActionRow> createState() => _ActionRowState();
}

class _ActionRowState extends State<_ActionRow> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: Duration(milliseconds: _down ? 0 : 200),
            color: _down
                ? (colors.dark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.06))
                : Colors.transparent,
            padding: const EdgeInsets.symmetric(vertical: 13),
            alignment: Alignment.center,
            child: Text(
              widget.label,
              style: TextStyle(color: widget.color, fontSize: 15.5),
            ),
          ),
        ),
      ),
    );
  }
}

/// The address large (the route bold, the part read out loud), the QR
/// code beside it on wide sheets or under it on phones, and the choice of
/// address when this device has several.
class _ShareCard extends StatelessWidget {
  const _ShareCard({
    required this.url,
    required this.route,
    required this.caption,
    required this.addresses,
    required this.selected,
    required this.tooltip,
    required this.onAddress,
    this.dimmed = false,
  });

  final String url;
  final String route;
  final String caption;
  final List<String> addresses;
  final String? selected;
  final String tooltip;
  final ValueChanged<String> onAddress;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    final cut = url.length - route.length;
    final address = SelectableText.rich(
      TextSpan(
        children: [
          TextSpan(text: url.substring(0, cut)),
          TextSpan(
            text: route,
            style: _mono.copyWith(
              color: colors.label,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
        ],
      ),
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 16, height: 1.4, color: colors.secondaryLabel),
    );
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: dimmed ? 0.45 : 1,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
        decoration: ShapeDecoration(
          color: _groupColor(colors),
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        child: Column(
          children: [
            _Qr(data: url),
            const SizedBox(height: 14),
            address,
            const SizedBox(height: 4),
            Text(
              caption,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.secondaryLabel, fontSize: 12),
            ),
            if (addresses.length > 1 && selected != null) ...[
              const SizedBox(height: 12),
              _AddressPicker(
                addresses: addresses,
                selected: selected!,
                tooltip: tooltip,
                onSelected: onAddress,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Picks which of this device's addresses the link shows, as a segmented
/// control.
class _AddressPicker extends StatelessWidget {
  const _AddressPicker({
    required this.addresses,
    required this.selected,
    required this.tooltip,
    required this.onSelected,
  });

  final List<String> addresses;
  final String selected;
  final String tooltip;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return Semantics(
      label: tooltip,
      child: CupertinoSlidingSegmentedControl<String>(
        groupValue: selected,
        backgroundColor: colors.dark
            ? Colors.white.withValues(alpha: 0.08)
            : Colors.black.withValues(alpha: 0.06),
        thumbColor: colors.dark ? const Color(0xFF636366) : Colors.white,
        onValueChanged: (value) {
          if (value != null) {
            HapticFeedback.selectionClick();
            onSelected(value);
          }
        },
        children: {
          for (final address in addresses)
            address: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text(
                address,
                maxLines: 1,
                style: _mono.copyWith(fontSize: 12.5, color: colors.label),
              ),
            ),
        },
      ),
    );
  }
}

class _Qr extends StatelessWidget {
  const _Qr({required this.data});

  final String data;

  @override
  Widget build(BuildContext context) {
    // Dark modules on white in both themes, so every camera reads it.
    return RepaintBoundary(
      child: Container(
        width: 176,
        height: 176,
        decoration: ShapeDecoration(
          color: Colors.white,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
          ),
        ),
        padding: const EdgeInsets.all(10),
        child: QrImageView(
          data: data,
          version: QrVersions.auto,
          gapless: true,
          backgroundColor: Colors.white,
          padding: EdgeInsets.zero,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: Color(0xFF1C1C1E),
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: Color(0xFF1C1C1E),
          ),
          semanticsLabel: data,
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({
    required this.icon,
    required this.color,
    required this.text,
    this.trailing,
  });

  final IconData icon;
  final Color color;
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final colors = FlowSpaceColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: ShapeDecoration(
        color: _groupColor(colors),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: colors.label,
                fontSize: 13.5,
                height: 1.3,
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

class _SheetButton extends StatefulWidget {
  const _SheetButton({
    required this.label,
    required this.color,
    required this.textColor,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.autofocus = false,
  });

  final String label;
  final Color color;
  final Color textColor;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final bool autofocus;

  @override
  State<_SheetButton> createState() => _SheetButtonState();
}

class _SheetButtonState extends State<_SheetButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.busy;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      excludeSemantics: true,
      child: FocusableActionDetector(
        autofocus: widget.autofocus,
        enabled: enabled,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onPressed?.call();
              return null;
            },
          ),
        },
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          onTapDown: enabled ? (_) => setState(() => _down = true) : null,
          onTapCancel: () => setState(() => _down = false),
          onTapUp: (_) => setState(() => _down = false),
          onTap: enabled ? widget.onPressed : null,
          child: AnimatedScale(
            duration: const Duration(milliseconds: 120),
            scale: _down ? 0.97 : 1,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 160),
              opacity: _down
                  ? 0.8
                  : widget.onPressed == null
                  ? 0.45
                  : 1,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                height: 48,
                alignment: Alignment.center,
                decoration: ShapeDecoration(
                  color: widget.color,
                  shape: RoundedSuperellipseBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: widget.busy
                    ? CupertinoActivityIndicator(
                        radius: 9,
                        color: widget.textColor,
                      )
                    : AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: Row(
                          key: ValueKey(widget.label),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.icon != null) ...[
                              Icon(
                                widget.icon,
                                size: 17,
                                color: widget.textColor,
                              ),
                              const SizedBox(width: 7),
                            ],
                            Flexible(
                              child: Text(
                                widget.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: widget.textColor,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
