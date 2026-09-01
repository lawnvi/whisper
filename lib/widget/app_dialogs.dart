import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import 'glass_dialog.dart';

class InputDialogField {
  const InputDialogField({
    required this.initialValue,
    required this.label,
    this.keyboardType,
    this.inputFormatters = const <TextInputFormatter>[],
    this.validator,
  });

  final String initialValue;
  final String label;
  final TextInputType? keyboardType;
  final List<TextInputFormatter> inputFormatters;
  final String? Function(String value)? validator;
}

Future<List<String>?> showValidatedInputDialog(
  BuildContext context, {
  required String title,
  String? description,
  required List<InputDialogField> fields,
  required String confirmButtonText,
  required String cancelButtonText,
}) {
  return showWhisperDialog<List<String>>(
    context,
    barrierDismissible: false,
    builder: (context) => _ValidatedInputDialog(
      title: title,
      description: description,
      fields: fields,
      confirmButtonText: confirmButtonText,
      cancelButtonText: cancelButtonText,
    ),
  );
}

Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String description,
  required String confirmButtonText,
  required String cancelButtonText,
  bool isDestructive = false,
}) async {
  return await showWhisperDialog<bool>(
        context,
        barrierDismissible: false,
        builder: (context) => _ConfirmationDialog(
          title: title,
          description: description,
          confirmButtonText: confirmButtonText,
          cancelButtonText: cancelButtonText,
          isDestructive: isDestructive,
        ),
      ) ??
      false;
}

@Deprecated('Use confirmAction and await its result')
void showConfirmationDialog(
  BuildContext context, {
  required String title,
  required String description,
  required String confirmButtonText,
  required String cancelButtonText,
  required VoidCallback onConfirm,
  VoidCallback? onCancel,
  bool isDestructive = false,
}) {
  unawaited(() async {
    final confirmed = await confirmAction(
      context,
      title: title,
      description: description,
      confirmButtonText: confirmButtonText,
      cancelButtonText: cancelButtonText,
      isDestructive: isDestructive,
    );
    if (confirmed) {
      onConfirm();
    } else {
      onCancel?.call();
    }
  }());
}

@Deprecated('Use showValidatedInputDialog and await its result')
void showInputAlertDialog(
  BuildContext context, {
  required String title,
  required String description,
  required List<Map<String, bool>> inputHints,
  required String confirmButtonText,
  required String cancelButtonText,
  required Function(List<String>) onConfirm,
}) {
  final fields = inputHints.map((hint) {
    final entry = hint.entries.first;
    return InputDialogField(
      initialValue: entry.key,
      label: entry.key,
      keyboardType: entry.value ? TextInputType.number : null,
      inputFormatters: entry.value
          ? <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly]
          : const <TextInputFormatter>[],
    );
  }).toList(growable: false);

  unawaited(() async {
    final values = await showValidatedInputDialog(
      context,
      title: title,
      description: description,
      fields: fields,
      confirmButtonText: confirmButtonText,
      cancelButtonText: cancelButtonText,
    );
    if (values != null) {
      onConfirm(values);
    }
  }());
}

class _ValidatedInputDialog extends StatefulWidget {
  const _ValidatedInputDialog({
    required this.title,
    required this.description,
    required this.fields,
    required this.confirmButtonText,
    required this.cancelButtonText,
  });

  final String title;
  final String? description;
  final List<InputDialogField> fields;
  final String confirmButtonText;
  final String cancelButtonText;

  @override
  State<_ValidatedInputDialog> createState() => _ValidatedInputDialogState();
}

class _ValidatedInputDialogState extends State<_ValidatedInputDialog> {
  late final List<TextEditingController> _controllers;
  late final List<String?> _errors;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _controllers = widget.fields
        .map((field) => TextEditingController(text: field.initialValue))
        .toList(growable: false);
    _errors = List<String?>.filled(widget.fields.length, null);
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _cancel() {
    if (_submitting) {
      return;
    }
    _submitting = true;
    Navigator.of(context).pop();
  }

  void _submit() {
    if (_submitting) {
      return;
    }
    final values = _controllers
        .map((controller) => controller.text.trim())
        .toList(growable: false);
    var hasError = false;
    for (var index = 0; index < widget.fields.length; index += 1) {
      final error = widget.fields[index].validator?.call(values[index]);
      _errors[index] = error;
      hasError = hasError || error != null;
    }
    if (hasError) {
      setState(() {});
      return;
    }
    _submitting = true;
    Navigator.of(context).pop(values);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final palette = context.whisperPalette;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
        const SingleActivator(LogicalKeyboardKey.enter): _submit,
      },
      child: WhisperGlassDialog(
        constraints: const BoxConstraints(
          minWidth: 300,
          maxWidth: 420,
          maxHeight: 680,
        ),
        title: Text(
          widget.title,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (widget.description?.isNotEmpty ?? false) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  widget.description!,
                  style: TextStyle(color: palette.textMuted),
                ),
                const SizedBox(height: 8),
              ],
              for (var index = 0;
                  index < widget.fields.length;
                  index += 1) ...<Widget>[
                const SizedBox(height: 8),
                CupertinoTextField(
                  controller: _controllers[index],
                  autofocus: index == 0,
                  keyboardType: widget.fields[index].keyboardType,
                  inputFormatters: widget.fields[index].inputFormatters,
                  textInputAction: TextInputAction.done,
                  placeholder: widget.fields[index].label,
                  style: TextStyle(color: colorScheme.onSurface),
                  decoration: BoxDecoration(
                    color: palette.surfaceElevated,
                    border: Border.all(
                      color: _errors[index] == null
                          ? palette.borderSubtle
                          : palette.danger,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                if (_errors[index] case final error?) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    error,
                    style: TextStyle(color: palette.danger, fontSize: 12),
                  ),
                ],
              ],
            ],
          ),
        ),
        actions: <Widget>[
          WhisperDialogButton(
            onPressed: _submitting ? null : _cancel,
            label: widget.cancelButtonText,
          ),
          WhisperDialogButton(
            onPressed: _submitting ? null : _submit,
            label: widget.confirmButtonText,
            prominent: true,
          ),
        ],
      ),
    );
  }
}

class _ConfirmationDialog extends StatefulWidget {
  const _ConfirmationDialog({
    required this.title,
    required this.description,
    required this.confirmButtonText,
    required this.cancelButtonText,
    required this.isDestructive,
  });

  final String title;
  final String description;
  final String confirmButtonText;
  final String cancelButtonText;
  final bool isDestructive;

  @override
  State<_ConfirmationDialog> createState() => _ConfirmationDialogState();
}

class _ConfirmationDialogState extends State<_ConfirmationDialog> {
  bool _submitting = false;

  void _complete(bool result) {
    if (_submitting) {
      return;
    }
    setState(() => _submitting = true);
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.whisperPalette;

    return WhisperGlassDialog(
      constraints: const BoxConstraints(
        minWidth: 300,
        maxWidth: 420,
        maxHeight: 620,
      ),
      title: Text(
        widget.title,
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(widget.description, style: TextStyle(color: palette.textMuted)),
        ],
      ),
      actions: <Widget>[
        WhisperDialogButton(
          onPressed: _submitting ? null : () => _complete(false),
          label: widget.cancelButtonText,
        ),
        WhisperDialogButton(
          onPressed: _submitting ? null : () => _complete(true),
          label: widget.confirmButtonText,
          prominent: true,
          destructive: widget.isDestructive,
        ),
      ],
    );
  }
}

Future<void> showLoadingDialog(
  BuildContext context, {
  required String title,
  required String description,
  required bool isLoading,
  required Widget icon,
  required String cancelButtonText,
  bool showCancel = true,
  required VoidCallback onCancel,
  required Function(VoidCallback onCancel) task,
}) async {
  final palette = context.whisperPalette;

  unawaited(
    showWhisperDialog<void>(
      context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return WhisperGlassDialog(
          constraints: const BoxConstraints(
            minWidth: 300,
            maxWidth: 420,
            maxHeight: 620,
          ),
          title: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const SizedBox(height: 12),
              if (isLoading) icon,
              const SizedBox(height: 8),
              Text(description, style: TextStyle(color: palette.textMuted)),
            ],
          ),
          actions: <Widget>[
            if (isLoading && showCancel)
              WhisperDialogButton(
                onPressed: onCancel,
                label: cancelButtonText,
                destructive: true,
              ),
          ],
        );
      },
    ),
  );
  await task(onCancel);
}
