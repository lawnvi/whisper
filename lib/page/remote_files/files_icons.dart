import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;

import '../../helper/device_form_factor.dart';
import '../../helper/transfer_notification_aggregator.dart'
    show formatBytesForNotification;
import '../../l10n/app_localizations.dart';
import '../../widget/device_glyph.dart';
import '../../remote_files/fs_browser.dart';
import '../../remote_files/fs_host_files.dart';
import 'files_model.dart';

/// Labels for places, by shortcut kind.
String fsPlaceLabel(AppLocalizations l10n, FsPlace place) =>
    switch (place.kind) {
      'root' => switch (place.rootKind) {
        'storage' => l10n.remoteFilesPlaceStorage,
        'documents' => l10n.remoteFilesPlaceAppFolder,
        'drive' =>
          place.label.isNotEmpty
              ? l10n.remoteFilesPlaceDrive(place.label, place.drive)
              : place.removable
              ? l10n.remoteFilesPlaceRemovableDisk(place.drive)
              : l10n.remoteFilesPlaceLocalDisk(place.drive),
        'volume' when place.label.isNotEmpty => place.label,
        _ =>
          place.root == 'storage'
              ? l10n.remoteFilesPlaceStorage
              : l10n.remoteFilesPlaceRoot,
      },
      'desktop' => l10n.remoteFilesPlaceDesktop,
      'documents' => l10n.remoteFilesPlaceDocuments,
      'downloads' => l10n.remoteFilesPlaceDownloads,
      'pictures' => l10n.remoteFilesPlacePictures,
      'camera' => l10n.remoteFilesPlaceCamera,
      'movies' => l10n.remoteFilesPlaceMovies,
      'music' => l10n.remoteFilesPlaceMusic,
      _ => place.path,
    };

/// "本机" for this device, else the device's own name.
String filesDeviceName(AppLocalizations l10n, FilesDevice device) =>
    device.isLocal ? l10n.remoteFilesThisDevice : device.name;

/// What a folder is called: a known place by its own name ("下载"),
/// anything else by its folder name.
String fsFolderLabel(
  AppLocalizations l10n,
  FilesDevice device,
  String root,
  String path,
) {
  for (final place in device.browser?.places ?? const <FsPlace>[]) {
    if (place.root == root && place.path == path) {
      return fsPlaceLabel(l10n, place);
    }
  }
  if (path.isEmpty) {
    return fsPlaceLabel(l10n, FsPlace(root: root, path: '', kind: 'root'));
  }
  return path.split('/').last;
}

/// Sidebar glyph for [place], outlined like Finder's: a root by what it
/// is (home, disk, removable volume…), a shortcut by its kind.
IconData fsPlaceGlyph(FsPlace place) => place.kind != 'root'
    ? fsPlaceIcon(place.kind)
    : switch (place.rootKind) {
        'drive' when place.removable => Icons.usb_rounded,
        'drive' => Icons.storage_rounded,
        'volume' => Icons.usb_rounded,
        'documents' => CupertinoIcons.folder,
        'storage' => CupertinoIcons.device_phone_portrait,
        _ => CupertinoIcons.house,
      };

/// Sidebar glyphs, outlined like Finder's.
IconData fsPlaceIcon(String kind) => switch (kind) {
  'root' => CupertinoIcons.house,
  'desktop' => CupertinoIcons.desktopcomputer,
  'documents' => CupertinoIcons.doc,
  'downloads' => CupertinoIcons.arrow_down_circle,
  'pictures' => CupertinoIcons.photo,
  'camera' => CupertinoIcons.camera,
  'movies' => CupertinoIcons.film,
  'music' => CupertinoIcons.music_note,
  _ => CupertinoIcons.folder,
};

IconData fsDeviceIcon(String platform, {bool tablet = false}) =>
    switch (platform) {
      'android' || 'ios' when tablet => tabletGlyph,
      'android' || 'ios' => CupertinoIcons.device_phone_portrait,
      'macos' => CupertinoIcons.device_laptop,
      _ => CupertinoIcons.desktopcomputer,
    };

/// [device]'s icon, a tablet's when it said it is one (show it with
/// [DeviceGlyph]).
IconData filesDeviceIcon(FilesDevice device) => fsDeviceIcon(
  device.platform,
  tablet: device.isLocal
      ? DeviceFormFactors.shared.localIsTablet
      : DeviceFormFactors.shared.isTablet(device.id),
);

String fsKindName(AppLocalizations l10n, FsKind kind) => switch (kind) {
  FsKind.folder => l10n.remoteFilesKindFolder,
  FsKind.image => l10n.remoteFilesKindImage,
  FsKind.video => l10n.remoteFilesKindVideo,
  FsKind.audio => l10n.remoteFilesKindAudio,
  FsKind.document => l10n.remoteFilesKindDocument,
  FsKind.archive => l10n.remoteFilesKindArchive,
  FsKind.code => l10n.remoteFilesKindCode,
  FsKind.app => l10n.remoteFilesKindApp,
  FsKind.other => l10n.remoteFilesKindOther,
};

/// "JPEG 图像", "文件夹": what Finder's Kind column says.
String fsKindLabel(AppLocalizations l10n, FsEntry entry) {
  final kind = fsKindName(l10n, entry.kind);
  final ext = _extension(entry.name);
  if (entry.isDir || ext.isEmpty) {
    return kind;
  }
  return l10n.remoteFilesKindNamed(ext, kind);
}

String _extension(String name) {
  final ext = p.extension(name);
  return ext.length > 1 && ext.length <= 6
      ? ext.substring(1).toUpperCase()
      : '';
}

String fsSizeLabel(FsEntry entry) =>
    entry.isDir ? '--' : formatBytesForNotification(entry.size);

/// "今天 10:24", "昨天 18:02", or the date and time.
String fsDateLabel(BuildContext context, int modifiedMs) {
  if (modifiedMs <= 0) {
    return '--';
  }
  final l10n = AppLocalizations.of(context)!;
  final locale = Localizations.localeOf(context).toLanguageTag();
  final when = DateTime.fromMillisecondsSinceEpoch(modifiedMs);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(when.year, when.month, when.day);
  final time = DateFormat.Hm(locale).format(when);
  if (day == today) {
    return l10n.remoteFilesToday(time);
  }
  if (day == today.subtract(const Duration(days: 1))) {
    return l10n.remoteFilesYesterday(time);
  }
  final date = when.year == now.year
      ? DateFormat.MMMd(locale).format(when)
      : DateFormat.yMMMd(locale).format(when);
  return '$date $time';
}

Color _kindHue(FsKind kind) => switch (kind) {
  FsKind.folder => const Color(0xFF3A97EA),
  FsKind.image => const Color(0xFF30B0C7),
  FsKind.video => const Color(0xFFAF52DE),
  FsKind.audio => const Color(0xFFFF2D55),
  FsKind.document => const Color(0xFF007AFF),
  FsKind.archive => const Color(0xFFA2845E),
  FsKind.code => const Color(0xFFFF9500),
  FsKind.app => const Color(0xFF5856D6),
  FsKind.other => const Color(0xFF8E8E93),
};

IconData _kindGlyph(FsKind kind) => switch (kind) {
  FsKind.image => CupertinoIcons.photo,
  FsKind.video => CupertinoIcons.play_fill,
  FsKind.audio => CupertinoIcons.music_note,
  FsKind.document => CupertinoIcons.text_alignleft,
  FsKind.archive => CupertinoIcons.archivebox_fill,
  FsKind.code => CupertinoIcons.chevron_left_slash_chevron_right,
  FsKind.app => CupertinoIcons.app_fill,
  _ => CupertinoIcons.doc,
};

/// A file's icon the way Finder draws it: a blue folder, a paper sheet with
/// a folded corner and the file's type, or the picture itself.
class FsFileIcon extends StatelessWidget {
  const FsFileIcon({
    super.key,
    required this.entry,
    required this.size,
    this.thumbnail,
    this.onAccent = false,
  });

  final FsEntry entry;
  final double size;
  final Uint8List? thumbnail;

  /// Shown on a row selected in the accent colour.
  final bool onAccent;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget icon;
    if (entry.isDir) {
      icon = CustomPaint(
        painter: _FolderPainter(dark: dark, onAccent: onAccent),
      );
    } else if (thumbnail != null) {
      icon = _Thumbnail(bytes: thumbnail!, size: size, dark: dark);
      if (entry.kind == FsKind.video && size >= 32) {
        icon = Stack(
          alignment: Alignment.center,
          children: [
            icon,
            Container(
              width: size * 0.34,
              height: size * 0.34,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.2),
              ),
              child: Icon(
                CupertinoIcons.play_fill,
                size: size * 0.17,
                color: Colors.white,
              ),
            ),
          ],
        );
      }
    } else {
      icon = _Sheet(entry: entry, size: size, dark: dark);
    }
    return SizedBox.square(dimension: size, child: icon);
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    required this.bytes,
    required this.size,
    required this.dark,
  });

  final Uint8List bytes;
  final double size;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final small = size < 32;
    final image = Image.memory(
      bytes,
      fit: small ? BoxFit.cover : BoxFit.contain,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
    );
    if (small) {
      return ClipRRect(borderRadius: BorderRadius.circular(3), child: image);
    }
    // A print with a thin white border, like Finder's previews.
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(3),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.5 : 0.18),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.all(size >= 56 ? 2.5 : 1.5),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: size, maxHeight: size),
            child: image,
          ),
        ),
      ),
    );
  }
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.entry, required this.size, required this.dark});

  final FsEntry entry;
  final double size;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final hue = _kindHue(entry.kind);
    final ext = _extension(entry.name);
    final large = size >= 40;
    return CustomPaint(
      painter: _SheetPainter(dark: dark, hue: hue),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          size * 0.2,
          size * 0.26,
          size * 0.2,
          size * 0.12,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Expanded(
              child: Center(
                child: Icon(
                  _kindGlyph(entry.kind),
                  size: size * (large ? 0.32 : 0.5),
                  color: hue,
                ),
              ),
            ),
            if (large && ext.isNotEmpty)
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  ext,
                  maxLines: 1,
                  style: TextStyle(
                    color: hue,
                    fontSize: size * 0.15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.4,
                    height: 1,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A sheet of paper with a folded top-right corner.
class _SheetPainter extends CustomPainter {
  const _SheetPainter({required this.dark, required this.hue});

  final bool dark;
  final Color hue;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final left = w * 0.16;
    final right = w * 0.84;
    final top = h * 0.06;
    final bottom = h * 0.94;
    final fold = w * 0.2;
    final r = w * 0.05;
    final sheet = Path()
      ..moveTo(left + r, top)
      ..lineTo(right - fold, top)
      ..lineTo(right, top + fold)
      ..lineTo(right, bottom - r)
      ..quadraticBezierTo(right, bottom, right - r, bottom)
      ..lineTo(left + r, bottom)
      ..quadraticBezierTo(left, bottom, left, bottom - r)
      ..lineTo(left, top + r)
      ..quadraticBezierTo(left, top, left + r, top)
      ..close();
    canvas.drawShadow(sheet, Colors.black, w * 0.02, false);
    canvas.drawPath(
      sheet,
      Paint()..color = dark ? const Color(0xFFE9E9EC) : Colors.white,
    );
    // A wash of the kind's colour, so small icons read at a glance.
    canvas.drawPath(sheet, Paint()..color = hue.withValues(alpha: 0.1));
    canvas.drawPath(
      sheet,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w < 32 ? 0.75 : 1
        ..color = Colors.black.withValues(alpha: dark ? 0.35 : 0.14),
    );
    final corner = Path()
      ..moveTo(right - fold, top)
      ..lineTo(right - fold, top + fold - r)
      ..quadraticBezierTo(
        right - fold,
        top + fold,
        right - fold + r,
        top + fold,
      )
      ..lineTo(right, top + fold)
      ..close();
    canvas.drawPath(
      corner,
      Paint()..color = Color.lerp(Colors.white, hue, 0.35)!,
    );
    canvas.drawPath(
      corner,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w < 32 ? 0.6 : 0.8
        ..color = Colors.black.withValues(alpha: 0.12),
    );
  }

  @override
  bool shouldRepaint(_SheetPainter old) => old.dark != dark || old.hue != hue;
}

/// The macOS folder: a darker back with a tab, a lighter front.
class _FolderPainter extends CustomPainter {
  const _FolderPainter({required this.dark, this.onAccent = false});

  final bool dark;

  /// Drawn on a selection in the accent colour: a light outline keeps the
  /// blue folder from vanishing into the blue row.
  final bool onAccent;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final r = w * 0.07;
    final left = w * 0.04;
    final right = w * 0.96;
    final backTop = h * 0.16;
    final bottom = h * 0.86;
    final tabRight = w * 0.42;
    final back = Path()
      ..moveTo(left, backTop + r)
      ..quadraticBezierTo(left, backTop, left + r, backTop)
      ..lineTo(tabRight - r, backTop)
      ..quadraticBezierTo(
        tabRight,
        backTop,
        tabRight + r * 0.8,
        backTop + h * 0.07,
      )
      ..lineTo(right - r, backTop + h * 0.07)
      ..quadraticBezierTo(
        right,
        backTop + h * 0.07,
        right,
        backTop + h * 0.07 + r,
      )
      ..lineTo(right, bottom - r)
      ..quadraticBezierTo(right, bottom, right - r, bottom)
      ..lineTo(left + r, bottom)
      ..quadraticBezierTo(left, bottom, left, bottom - r)
      ..close();
    canvas.drawPath(
      back,
      Paint()..color = dark ? const Color(0xFF2B80D3) : const Color(0xFF3A97EA),
    );
    final front = RRect.fromLTRBR(
      left,
      h * 0.3,
      right,
      bottom,
      Radius.circular(r),
    );
    canvas.drawRRect(
      front,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: dark
              ? const [Color(0xFF5DAEF4), Color(0xFF358BDD)]
              : const [Color(0xFF7DC2FA), Color(0xFF4BA5F2)],
        ).createShader(front.outerRect),
    );
    // A light edge along the front's top, as on the real icon.
    canvas.drawLine(
      Offset(left + r, h * 0.3 + 0.5),
      Offset(right - r, h * 0.3 + 0.5),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.45)
        ..strokeWidth = w < 32 ? 0.6 : 1,
    );
    if (onAccent) {
      final outline = Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white.withValues(alpha: 0.9)
        ..strokeWidth = w < 32 ? 1 : 1.5;
      canvas
        ..drawPath(back, outline)
        ..drawRRect(front, outline);
    }
  }

  @override
  bool shouldRepaint(_FolderPainter old) =>
      old.dark != dark || old.onAccent != onAccent;
}
