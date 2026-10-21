import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:xml/xml.dart';

/// The places of KDE's Dolphin and file dialogs (user-places.xbel). KDE
/// lists a mount there only when it knows its kind (NFS, SMB, sshfs and a
/// few more), never Whisper's, so each mount is put there as a place of its
/// own; GNOME and the file managers built on GIO list a mount in the home
/// folder themselves. Whisper's places carry [_markKey] (the mount's path):
/// found by it, and nobody else's ever touched. KDE notices the file change.
abstract final class KdePlaces {
  static const _markKey = 'WhisperMount';

  /// Puts [path] last among the places, as [title], with a disk's icon as
  /// GNOME shows it (Whisper's own is a blank circle that small).
  static Future<bool> add(String path, {required String title}) => _change(
    (xbel) => withPlace(xbel, path, title: title, icon: 'drive-harddisk'),
  );

  /// Takes [path] out again.
  static Future<bool> remove(String path) =>
      _change((xbel) => without(xbel, (mark) => mark == path));

  /// Takes out every one of Whisper's: what a run before this one left.
  static Future<bool> removeAll() =>
      _change((xbel) => without(xbel, (_) => true));

  /// Only a file KDE made: without one KDE writes its default places,
  /// which a file holding Whisper's alone would keep it from doing.
  static Future<bool> _change(String? Function(String xbel) change) async {
    final env = Platform.environment;
    final data =
        env['XDG_DATA_HOME'] ??
        (env['HOME'] == null ? null : '${env['HOME']}/.local/share');
    if (data == null) {
      return false;
    }
    final file = File('$data/user-places.xbel');
    try {
      final changed = change(await file.readAsString());
      if (changed != null) {
        // Put in place at once, as KDE saves it.
        final next = File('${file.path}.whisper');
        await next.writeAsString(changed, flush: true);
        await next.rename(file.path);
      }
      return true;
    } on FileSystemException {
      return false;
    } on XmlException {
      return false;
    }
  }

  /// [xbel] with [path] as its last place; null when it is there already.
  @visibleForTesting
  static String? withPlace(
    String xbel,
    String path, {
    required String title,
    required String icon,
  }) {
    final document = XmlDocument.parse(xbel);
    final root = document.rootElement;
    if (_marked(root, (mark) => mark == path).isNotEmpty) {
      return null;
    }
    final now = DateTime.now();
    final builder = XmlBuilder();
    builder.element(
      'bookmark',
      attributes: {'href': Uri.file(path).toString()},
      nest: () {
        builder
          ..element('title', nest: title)
          ..element(
            'info',
            nest: () {
              builder
                ..element(
                  'metadata',
                  attributes: {'owner': 'http://freedesktop.org'},
                  nest: () {
                    builder.element(
                      'bookmark:icon',
                      attributes: {'name': icon},
                    );
                  },
                )
                ..element(
                  'metadata',
                  attributes: {'owner': 'http://www.kde.org'},
                  nest: () {
                    builder
                      ..element(
                        'ID',
                        nest:
                            '${now.millisecondsSinceEpoch ~/ 1000}/'
                            'whisper${now.microsecondsSinceEpoch % 1000000}',
                      )
                      ..element(_markKey, nest: path);
                  },
                );
            },
          );
      },
    );
    // Laid out like KDE's own places: a space a level, one level in.
    final place = builder
        .buildFragment()
        .firstElementChild!
        .toXmlString(pretty: true, indent: ' ')
        .replaceAll('\n', '\n ');
    final last = root.children.lastOrNull;
    final at = last is XmlText && last.value.trim().isEmpty
        ? root.children.length - 1
        : root.children.length;
    root.children.insertAll(at, [
      XmlText('\n '),
      for (final node in XmlDocumentFragment.parse(place).children) node.copy(),
    ]);
    return document.toXmlString();
  }

  /// [xbel] without Whisper's places whose mark [which] takes; null when
  /// it has none.
  @visibleForTesting
  static String? without(String xbel, bool Function(String mark) which) {
    final document = XmlDocument.parse(xbel);
    final places = _marked(document.rootElement, which);
    if (places.isEmpty) {
      return null;
    }
    for (final place in places) {
      final before = place.previousSibling;
      if (before is XmlText && before.value.trim().isEmpty) {
        before.remove();
      }
      place.remove();
    }
    return document.toXmlString();
  }

  static List<XmlElement> _marked(
    XmlElement root,
    bool Function(String mark) which,
  ) => [
    for (final place in root.childElements)
      if (place.name.local == 'bookmark' &&
          place.findAllElements(_markKey).any((mark) => which(mark.innerText)))
        place,
  ];
}
