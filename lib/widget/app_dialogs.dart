import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

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
  return showDialog<List<String>>(
    context: context,
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
  return await showDialog<bool>(
        context: context,
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
  final _formKey = GlobalKey<FormState>();
  late final List<TextEditingController> _controllers;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _controllers = widget.fields
        .map((field) => TextEditingController(text: field.initialValue))
        .toList(growable: false);
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
    if (_submitting || !(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    _submitting = true;
    Navigator.of(context).pop(
      _controllers.map((controller) => controller.text.trim()).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): _cancel,
        const SingleActivator(LogicalKeyboardKey.enter): _submit,
      },
      child: AlertDialog(
        title: Text(widget.title),
        content: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (widget.description?.isNotEmpty ?? false) ...<Widget>[
                  Text(
                    widget.description!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: context.whisperPalette.textMuted,
                        ),
                  ),
                  const SizedBox(height: 16),
                ],
                for (var index = 0;
                    index < widget.fields.length;
                    index += 1) ...<Widget>[
                  if (index > 0) const SizedBox(height: 12),
                  TextFormField(
                    controller: _controllers[index],
                    autofocus: index == 0,
                    keyboardType: widget.fields[index].keyboardType,
                    inputFormatters: widget.fields[index].inputFormatters,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: widget.fields[index].label,
                    ),
                    validator: (value) => widget.fields[index].validator
                        ?.call((value ?? '').trim()),
                    onFieldSubmitted: (_) => _submit(),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: _submitting ? null : _cancel,
            child: Text(widget.cancelButtonText),
          ),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: Text(widget.confirmButtonText),
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
    final colorScheme = Theme.of(context).colorScheme;
    final confirmColor = widget.isDestructive
        ? context.whisperPalette.danger
        : colorScheme.primary;

    return AlertDialog(
      title: Text(widget.title),
      content: Text(widget.description),
      actions: <Widget>[
        TextButton(
          autofocus: true,
          style: TextButton.styleFrom(foregroundColor: colorScheme.onSurface),
          onPressed: _submitting ? null : () => _complete(false),
          child: Text(widget.cancelButtonText),
        ),
        TextButton(
          style: TextButton.styleFrom(foregroundColor: confirmColor),
          onPressed: _submitting ? null : () => _complete(true),
          child: Text(widget.confirmButtonText),
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

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) {
      return CupertinoAlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SizedBox(height: 12),
            if (isLoading) icon,
            const SizedBox(height: 8),
            Text(
              description,
              style: TextStyle(color: palette.textMuted),
            ),
          ],
        ),
        actions: <Widget>[
          if (isLoading && showCancel)
            CupertinoDialogAction(
              onPressed: onCancel,
              child: Text(
                cancelButtonText,
                style: TextStyle(color: palette.textMuted),
              ),
            ),
        ],
      );
    },
  );
  await task(onCancel);
}
