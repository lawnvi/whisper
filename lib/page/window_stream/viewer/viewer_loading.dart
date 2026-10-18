import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../flow_space_theme.dart';

/// How long the placeholder and the live picture take to swap.
const viewerCrossfade = Duration(milliseconds: 180);

/// The crossfade's duration here: none when the system asks for less
/// motion.
Duration viewerFadeDuration(BuildContext context) =>
    flowReduceMotion(context) ? Duration.zero : viewerCrossfade;

/// What the viewer shows until the streamed picture settles: over an
/// opaque black ground (the live picture underneath stays hidden, stretched
/// early frames and all), the window's last known picture (aspect-fit,
/// dimmed) or without one the app's icon, a spinner in the middle, and only
/// after a long wait a "still connecting" line. Once the picture is stable
/// the whole stage fades out over it: the crossfade.
///
/// With [dimOnly] it covers a picture that is already there (after a
/// resume, while the first new frame is late): a light dim and the
/// spinner, see-through.
class ViewerLoadingStage extends StatelessWidget {
  const ViewerLoadingStage({
    super.key,
    required this.visible,
    this.image,
    this.icon,
    this.slowText,
    this.dimOnly = false,
    this.spinner = true,
  });

  /// Shown (fades in and out with the crossfade).
  final bool visible;

  /// The window's last picture as a JPEG/PNG, if one is known.
  final Uint8List? image;

  /// The app's icon (PNG), shown when there is no [image].
  final Uint8List? icon;

  static const double iconSize = 64;

  /// Shown under the spinner when the wait has been long; null hides it.
  final String? slowText;
  final bool dimOnly;

  /// The spinner (left out under another overlay that has its own).
  final bool spinner;

  static const Color _dim = Color(0x59000000);

  @override
  Widget build(BuildContext context) {
    final image = this.image;
    final icon = dimOnly || image != null ? null : this.icon;
    return IgnorePointer(
      child: AnimatedOpacity(
        key: const ValueKey('viewer-loading'),
        duration: viewerFadeDuration(context),
        curve: Curves.easeOut,
        opacity: visible ? 1 : 0,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (!dimOnly) const ColoredBox(color: Colors.black),
            // A thumbnail arriving late fades in rather than popping.
            AnimatedSwitcher(
              duration: viewerFadeDuration(context),
              child: !dimOnly && image != null
                  ? Image.memory(
                      image,
                      key: ObjectKey(image),
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.medium,
                    )
                  : const SizedBox.expand(),
            ),
            if (dimOnly || image != null) const ColoredBox(color: _dim),
            if (spinner)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedSize(
                      duration: viewerFadeDuration(context),
                      child: icon == null
                          ? const SizedBox(width: 0, height: 0)
                          : Padding(
                              padding: const EdgeInsets.only(bottom: 22),
                              child: Image.memory(
                                icon,
                                key: ObjectKey(icon),
                                width: iconSize,
                                height: iconSize,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                                filterQuality: FilterQuality.medium,
                              ),
                            ),
                    ),
                    const CupertinoActivityIndicator(
                      color: Colors.white,
                      radius: 14,
                    ),
                    AnimatedSize(
                      duration: viewerFadeDuration(context),
                      child: slowText == null
                          ? const SizedBox(width: 0, height: 0)
                          : Padding(
                              padding: const EdgeInsets.only(top: 14),
                              child: Text(
                                slowText!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                  shadows: [
                                    Shadow(
                                      color: Color(0x99000000),
                                      blurRadius: 8,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
