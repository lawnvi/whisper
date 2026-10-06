import 'dart:async';

import 'package:flutter/material.dart';
import 'package:whisper/helper/local.dart';
import 'package:whisper/l10n/app_localizations.dart';
import 'package:whisper/remote_input/mobile_input_controller.dart';
import 'package:whisper/theme/app_theme.dart';

class MobilePointerSettings extends StatelessWidget {
  const MobilePointerSettings({
    super.key,
    required this.controller,
    required this.sensorsAvailable,
    required this.enabled,
    required this.onCalibrate,
  });

  final MobileInputController controller;
  final bool sensorsAvailable;
  final bool enabled;
  final VoidCallback onCalibrate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.mobileControlSettings,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 24),
          _speedSlider(
            l10n.mobileControlPointerSpeed,
            controller.pointerSpeed,
            controller.setPointerSpeed,
            LocalSetting().setMobilePointerSpeed,
          ),
          _speedSlider(
            l10n.mobileControlScrollSpeed,
            controller.scrollSpeed,
            controller.setScrollSpeed,
            LocalSetting().setMobileScrollSpeed,
          ),
          if (sensorsAvailable) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: Text(l10n.mobileControlSensitivity)),
                Text(
                  '${controller.motion.sensitivity.toStringAsFixed(2)}×',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            Slider(
              value: controller.motion.sensitivity,
              min: 0.5,
              max: 3,
              divisions: 10,
              onChanged: controller.setSensitivity,
              onChangeEnd: (value) =>
                  unawaited(LocalSetting().setMobileInputSensitivity(value)),
            ),
            Text(
              l10n.mobileControlPrecisionHint,
              style: TextStyle(color: context.whisperPalette.textMuted),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.center_focus_strong_rounded),
                onPressed: !enabled || controller.motion.calibrating
                    ? null
                    : onCalibrate,
                label: Text(
                  controller.motion.calibrating
                      ? l10n.mobileControlCalibrating
                      : l10n.mobileControlCalibrate,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _speedSlider(
    String label,
    double value,
    ValueChanged<double> onChanged,
    Future<void> Function(double) save,
  ) => Column(
    children: [
      Row(
        children: [
          Expanded(child: Text(label)),
          Text('${value.toStringAsFixed(2)}×'),
        ],
      ),
      Slider(
        value: value,
        min: 0.5,
        max: 3,
        divisions: 10,
        label: label,
        onChanged: onChanged,
        onChangeEnd: (value) => unawaited(save(value)),
      ),
    ],
  );
}
