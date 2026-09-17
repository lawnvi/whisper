import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:whisper/cast_receiver/request_gate.dart';
import 'package:whisper/l10n/app_localizations.dart';

class CastRequestPrompt extends StatefulWidget {
  const CastRequestPrompt({
    super.key,
    required this.request,
    required this.gate,
  });
  final CastRequest request;
  final CastRequestGate gate;

  @override
  State<CastRequestPrompt> createState() => _CastRequestPromptState();
}

class _CastRequestPromptState extends State<CastRequestPrompt> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_present()));
  }

  Future<void> _present() async {
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    } on Object {
      // The prompt still works if the desktop denies window activation.
    }
    if (mounted) widget.gate.presented(widget.request);
  }

  void _decide(bool allowed) => widget.gate.decide(widget.request, allowed);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colors = Theme.of(context).colorScheme;
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _decide(false);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          const ModalBarrier(dismissible: false, color: Colors.black38),
          Center(
            child: Dialog(
              constraints: const BoxConstraints(maxWidth: 420),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.tv_rounded, color: colors.primary, size: 24),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            l10n.castRequestTitle,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.castRequestMessage(widget.request.address),
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(height: 1.5),
                    ),
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        l10n.castRequestCountdown(
                          widget.request.secondsRemaining,
                        ),
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                          onPressed: () => _decide(false),
                          child: Text(l10n.castRequestDeny),
                        ),
                        const SizedBox(width: 12),
                        FilledButton(
                          onPressed: () => _decide(true),
                          child: Text(l10n.castRequestAllow),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
