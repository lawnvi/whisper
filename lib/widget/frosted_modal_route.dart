import 'dart:ui';

import 'package:flutter/material.dart';

double whisperModalBlurSigma(BuildContext context) {
  return MediaQuery.highContrastOf(context) ? 0 : 2.0;
}

mixin WhisperFrostedModalBarrier<T> on ModalRoute<T> {
  double get barrierBlurSigma;

  @override
  Widget buildModalBarrier() {
    final barrier = super.buildModalBarrier();
    if (barrierBlurSigma == 0) {
      return barrier;
    }
    // Blur the barrier's backdrop, so the dialog stays sharp and the filter
    // covers the window independently of the dialog's scale/slide transition.
    return AnimatedBuilder(
      animation: animation!,
      child: barrier,
      builder: (context, child) {
        final sigma =
            barrierBlurSigma * barrierCurve.transform(animation!.value);
        return ClipRect(
          child: BackdropFilter(
            key: const ValueKey<String>('whisper-modal-backdrop'),
            filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
            child: child,
          ),
        );
      },
    );
  }
}

class WhisperFrostedPageRoute<T> extends PageRouteBuilder<T>
    with WhisperFrostedModalBarrier<T> {
  WhisperFrostedPageRoute({
    required this.barrierBlurSigma,
    required super.pageBuilder,
    required super.transitionsBuilder,
    required super.transitionDuration,
    required super.reverseTransitionDuration,
    super.barrierDismissible,
    super.barrierColor,
    super.barrierLabel,
    super.settings,
  }) : super(opaque: false, allowSnapshotting: false);

  @override
  final double barrierBlurSigma;
}

class WhisperFrostedBottomSheetRoute<T> extends ModalBottomSheetRoute<T>
    with WhisperFrostedModalBarrier<T> {
  WhisperFrostedBottomSheetRoute({
    required this.barrierBlurSigma,
    required super.builder,
    required super.isScrollControlled,
    super.capturedThemes,
    super.barrierLabel,
    super.barrierOnTapHint,
    super.modalBarrierColor,
    super.backgroundColor,
    super.constraints,
    super.shape,
    super.showDragHandle,
    super.useSafeArea,
    super.sheetAnimationStyle,
  });

  @override
  final double barrierBlurSigma;
}
