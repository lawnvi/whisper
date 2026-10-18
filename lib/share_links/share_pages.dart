import 'dart:convert';

import 'package:flutter/widgets.dart' show Locale;
import 'package:path/path.dart' as p;

import '../l10n/app_localizations.dart';
import '../remote_files/fs_host_files.dart' show FsKind, fsKindOf;

/// A file as its own page: alone in a link, or opened from a folder.
class ShareFileView {
  const ShareFileView({
    required this.name,
    required this.size,
    required this.modified,
    required this.downloadHref,
    required this.openHref,
    required this.previewHref,
    this.crumbs = const [],
    this.previousHref,
    this.nextHref,
    this.position,
    this.textPreview,
    this.textTruncated = false,
    this.textLimit = 0,
  });

  final String name;
  final int size;
  final DateTime modified;
  final String downloadHref;

  /// The file itself, for the browser to show.
  final String openHref;

  /// The file for an `<img>`/`<video>`/`<audio>` on the page (not counted
  /// as a download).
  final String previewHref;

  /// The folders above it, each with its page; empty for a lone file.
  final List<(String label, String href)> crumbs;

  /// Neighbours in its folder, and where it is among them (1-based).
  final String? previousHref;
  final String? nextHref;
  final (int index, int count)? position;

  /// The start of a text file, already decoded.
  final String? textPreview;
  final bool textTruncated;

  /// How much of the file [textPreview] covers at most, in bytes.
  final int textLimit;
}

/// The web pages a share link shows in a browser: self-contained HTML with
/// inline CSS and SVG, no script, light and dark following the system,
/// laid out for phones first and widening into columns on desktops.
class SharePages {
  SharePages({
    required this.text,
    required this.languageTag,
    required this.deviceName,
    this.devicePlatform = '',
    DateTime? now,
  }) : now = now ?? DateTime.now();

  final AppLocalizations text;

  /// For `<html lang>`.
  final String languageTag;
  final String deviceName;

  /// `Platform.operatingSystem` of the sharing device, for its glyph.
  final String devicePlatform;
  final DateTime now;

  /// A file on its own page: a preview where browsers can show one (or a
  /// large icon), its name and facts, a download button that carries the
  /// size, and the way back to its folder.
  String file(ShareFileView view) {
    final name = view.name;
    final preview = sharePreviewOf(name);
    final snippet = view.textPreview;
    final media =
        preview == SharePreview.image || preview == SharePreview.video;
    final body = StringBuffer()
      ..write(media ? '<main class="wrap wide">' : '<main class="wrap mid">');
    body.write(_crumbs(view.crumbs, name));
    final kind = media
        ? ' media'
        : snippet != null && preview != SharePreview.audio
        ? ' textual'
        : '';
    body.write('<article class="card file$kind">');
    // The stage: what the file looks like.
    switch (preview) {
      case SharePreview.image:
        body.write(
          '<div class="stage photo"><img src="${_a(view.previewHref)}" '
          'alt="${_a(name)}" decoding="async"></div>',
        );
      case SharePreview.video:
        body.write(
          '<div class="stage movie"><video src="${_a(view.previewHref)}" '
          'controls playsinline preload="metadata"></video></div>',
        );
      case SharePreview.audio:
        body.write(
          '<div class="stage sound"><div class="icon-hero">'
          '${_fileIcon(name)}</div><audio src="${_a(view.previewHref)}" '
          'controls preload="metadata"></audio></div>',
        );
      case _ when snippet != null:
        body
          ..write('<div class="stage text"><pre tabindex="0">')
          ..write(_e(snippet))
          ..write('</pre>');
        if (view.textTruncated) {
          body.write(
            '<p class="note">${_e(text.shareWebPreviewTruncated(_size(view.textLimit)))}</p>',
          );
        }
        body.write('</div>');
      default:
        body.write(
          '<div class="stage plain"><div class="icon-hero">'
          '${_fileIcon(name)}</div></div>',
        );
    }
    // The facts and actions.
    body
      ..write('<div class="info">')
      ..write('<h1 class="file-name">${_e(name)}</h1>')
      ..write('<p class="facts">')
      ..write(
        '<span class="chip"><i style="background:${_hueOf(name)}"></i>'
        '${_e(_kindLabel(name))}</span>',
      )
      ..write('<span>${_e(_size(view.size))}</span>')
      ..write('<span>${_e(_date(view.modified))}</span>')
      ..write('</p><div class="actions">')
      ..write(
        '<a class="btn primary big" href="${_a(view.downloadHref)}" download>'
        '$_downloadGlyph<span>${_e(text.shareWebDownload)}</span>'
        '<span class="size">${_e(_size(view.size))}</span></a>',
      );
    if (preview != null) {
      body.write(
        '<a class="btn secondary big" href="${_a(view.openHref)}" '
        'target="_blank" rel="noopener">$_openGlyph'
        '<span>${_e(text.shareWebOpen)}</span></a>',
      );
    }
    body.write('</div>');
    final position = view.position;
    if (view.previousHref != null || view.nextHref != null) {
      body.write('<nav class="pager">');
      body.write(
        view.previousHref == null
            ? '<span class="btn ghost off">$_backGlyph<span>${_e(text.shareWebPrevious)}</span></span>'
            : '<a class="btn ghost" rel="prev" href="${_a(view.previousHref!)}">'
                  '$_backGlyph<span>${_e(text.shareWebPrevious)}</span></a>',
      );
      if (position != null) {
        body.write(
          '<span class="count">${position.$1} / ${position.$2}</span>',
        );
      }
      body.write(
        view.nextHref == null
            ? '<span class="btn ghost off"><span>${_e(text.shareWebNext)}</span>$_chevronGlyph</span>'
            : '<a class="btn ghost" rel="next" href="${_a(view.nextHref!)}">'
                  '<span>${_e(text.shareWebNext)}</span>$_chevronGlyph</a>',
      );
      body.write('</nav>');
    }
    body.write('</div></article></main>');
    return _document(name, body.toString(), width: media ? 'wide' : '');
  }

  /// A folder, or several shared items: where it is, what it is called,
  /// "download all", then one row per entry (folders first). On desktops
  /// the rows line up in name, date and size columns.
  String folder({
    required String title,
    required List<(String label, String href)> crumbs,
    required List<ShareRow> rows,
    required String zipHref,
    bool count = true,
  }) {
    final files = rows.where((row) => !row.isDir).toList();
    final total = files.fold<int>(0, (sum, row) => sum + row.size);
    final body = StringBuffer()..write('<main class="wrap">');
    body.write(_crumbs(crumbs, title));
    body
      ..write('<section class="head">')
      ..write('<div class="head-icon">${_folderIcon()}</div>')
      ..write('<div class="head-text"><h1>${_e(title)}</h1>')
      ..write('<p class="meta">');
    // A title that already says "3 items" is not followed by "3 items".
    final facts = [
      if (count) text.shareWebItemCount(rows.length),
      if (files.isNotEmpty) _size(total),
    ];
    body.write(_e(facts.join(' · ')));
    body.write('</p></div>');
    if (rows.isNotEmpty) {
      body.write(
        '<a class="btn primary" href="${_a(zipHref)}" download>'
        '$_downloadGlyph<span>${_e(text.shareWebDownloadAll)}</span></a>',
      );
    }
    body.write('</section>');
    if (rows.isEmpty) {
      body.write(
        '<section class="card empty">${_folderIcon(outline: true)}'
        '<p>${_e(text.shareWebEmptyFolder)}</p></section>',
      );
    } else {
      body
        ..write('<div class="card table" role="table">')
        ..write('<div class="thead" role="row">')
        ..write(
          '<span role="columnheader">${_e(text.remoteFilesColumnName)}</span>',
        )
        ..write(
          '<span role="columnheader" class="c-date">'
          '${_e(text.remoteFilesColumnModified)}</span>',
        )
        ..write(
          '<span role="columnheader" class="c-size">'
          '${_e(text.remoteFilesColumnSize)}</span>',
        )
        ..write('<span role="columnheader" class="c-act"></span></div>')
        ..write('<ul class="rows" role="rowgroup">');
      for (final row in rows) {
        final date = _date(row.modified, short: true);
        final size = row.isDir ? '' : _size(row.size);
        final sub = row.isDir ? date : '$size · $date';
        body
          ..write('<li class="row" role="row">')
          ..write('<a class="c-name" role="cell" href="${_a(row.href)}">')
          ..write('<span class="icon">')
          ..write(row.isDir ? _folderIcon() : _fileIcon(row.name))
          ..write('</span><span class="names"><span class="n">')
          ..write(_e(row.name))
          ..write('</span><span class="sub">${_e(sub)}</span></span></a>')
          ..write('<span class="c-date" role="cell">${_e(date)}</span>')
          ..write('<span class="c-size" role="cell">${_e(size)}</span>');
        if (row.isDir) {
          body.write(
            '<a class="c-act go" role="cell" href="${_a(row.href)}" '
            'tabindex="-1" aria-hidden="true">$_chevronGlyph</a>',
          );
        } else {
          final label = '${text.shareWebDownload} ${row.name}';
          body.write(
            '<a class="c-act dl" role="cell" href="${_a(row.downloadHref)}" '
            'download aria-label="${_a(label)}" '
            'title="${_a(text.shareWebDownload)}">$_downloadGlyph</a>',
          );
        }
        body.write('</li>');
      }
      body.write('</ul></div>');
    }
    body.write('</main>');
    return _document(title, body.toString());
  }

  /// Asks for the link's password.
  String login({
    required String action,
    required String next,
    bool wrong = false,
  }) {
    final body = StringBuffer()
      ..write('<main class="wrap narrow center"><section class="card panel">')
      ..write('<div class="badge accent">$_lockGlyph</div>')
      ..write('<h1>${_e(text.shareWebPasswordTitle)}</h1>')
      ..write('<p class="lead">${_e(text.shareWebPasswordDetail)}</p>')
      ..write('<form method="post" action="${_a(action)}" class="form">')
      ..write('<input type="hidden" name="next" value="${_a(next)}">')
      ..write(
        '<label class="field${wrong ? ' invalid' : ''}">$_keyGlyph'
        '<input type="password" name="password" '
        'autocomplete="current-password" autofocus required '
        'aria-label="${_a(text.shareLinkPassword)}" '
        'placeholder="${_a(text.shareLinkPassword)}"'
        '${wrong ? ' aria-invalid="true" aria-describedby="err"' : ''}>'
        '</label>',
      );
    if (wrong) {
      body.write(
        '<p class="error" id="err" role="alert">$_alertGlyph'
        '<span>${_e(text.shareWebPasswordWrong)}</span></p>',
      );
    }
    body
      ..write(
        '<button class="btn primary big" type="submit">'
        '<span>${_e(text.shareWebContinue)}</span></button>',
      )
      ..write('</form></section></main>');
    return _document(text.shareWebPasswordTitle, body.toString());
  }

  /// A page that explains why nothing is shown.
  String message(ShareMessage kind, {String? backHref}) {
    final (title, detail, glyph, tone) = switch (kind) {
      ShareMessage.notFound => (
        text.shareWebNotFoundTitle,
        text.shareWebNotFoundDetail,
        _linkOffGlyph,
        'muted',
      ),
      ShareMessage.missing => (
        text.shareWebMissingTitle,
        text.shareWebMissingDetail,
        _questionGlyph,
        'muted',
      ),
      ShareMessage.tooMany => (
        text.shareWebTooManyTitle,
        text.shareWebTooManyDetail,
        _clockGlyph,
        'warn',
      ),
      ShareMessage.error => (
        text.shareWebErrorTitle,
        text.shareWebErrorDetail,
        _warningGlyph,
        'danger',
      ),
    };
    final body = StringBuffer()
      ..write('<main class="wrap narrow center"><section class="card panel">')
      ..write('<div class="badge $tone">$glyph</div>')
      ..write('<h1>${_e(title)}</h1>')
      ..write('<p class="lead">${_e(detail)}</p>');
    if (backHref != null) {
      body.write(
        '<div class="actions"><a class="btn secondary big" '
        'href="${_a(backHref)}">$_backGlyph<span>${_e(text.shareWebBack)}</span></a></div>',
      );
    }
    body.write('</section></main>');
    return _document(title, body.toString());
  }

  String _crumbs(List<(String label, String href)> crumbs, String current) {
    if (crumbs.isEmpty) {
      return '';
    }
    final out = StringBuffer()
      ..write('<nav class="crumbs" aria-label="breadcrumb">');
    // Phones: just the way up. Wider screens: the whole path.
    final (upLabel, upHref) = crumbs.last;
    out.write(
      '<a class="up" href="${_a(upHref)}">$_backGlyph<span>${_e(upLabel)}</span></a>',
    );
    out.write('<ol class="path">');
    for (var i = 0; i < crumbs.length; i++) {
      final (label, href) = crumbs[i];
      out.write(
        '<li><a href="${_a(href)}">${i == 0 ? _homeGlyph : ''}'
        '<span>${_e(label)}</span></a><i aria-hidden="true">'
        '$_chevronGlyph</i></li>',
      );
    }
    out.write(
      '<li aria-current="page"><span class="here">${_e(current)}</span></li>',
    );
    out.write('</ol></nav>');
    return out.toString();
  }

  String _document(String title, String body, {String width = ''}) {
    return '<!doctype html><html lang="${_a(languageTag)}"><head>'
        '<meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1, '
        'viewport-fit=cover">'
        '<meta name="color-scheme" content="light dark">'
        '<meta name="theme-color" content="#f5f5f7" '
        'media="(prefers-color-scheme: light)">'
        '<meta name="theme-color" content="#000000" '
        'media="(prefers-color-scheme: dark)">'
        '<meta name="robots" content="noindex, nofollow">'
        '<meta name="referrer" content="no-referrer">'
        '<title>${_e(title)} — Whisper</title>'
        '<link rel="icon" href="$_favicon">'
        '<link rel="apple-touch-icon" href="/apple-touch-icon.png">'
        '<style>$_css</style></head><body>'
        '$_defs'
        '<header class="bar"><div class="bar-in $width">'
        '<span class="brand">$_brandMark<span>Whisper</span></span>'
        '<span class="device">${_deviceGlyph(devicePlatform)}'
        '<span>${_e(text.shareWebFrom(deviceName))}</span></span>'
        '</div></header>'
        '$body'
        '<footer><p>$_shieldGlyph${_e(text.shareWebFooterLan)}</p>'
        '</footer></body></html>';
  }

  String _kindLabel(String name) {
    final kind = fsKindOf(name);
    final kindName = switch (kind) {
      FsKind.folder => text.remoteFilesKindFolder,
      FsKind.image => text.remoteFilesKindImage,
      FsKind.video => text.remoteFilesKindVideo,
      FsKind.audio => text.remoteFilesKindAudio,
      FsKind.document => text.remoteFilesKindDocument,
      FsKind.archive => text.remoteFilesKindArchive,
      FsKind.code => text.remoteFilesKindCode,
      FsKind.app => text.remoteFilesKindApp,
      FsKind.other => text.remoteFilesKindOther,
    };
    final ext = _extension(name);
    return ext.isEmpty ? kindName : text.remoteFilesKindNamed(ext, kindName);
  }

  /// "今天 10:24", "昨天 18:02", or the date; [short] leaves out the time
  /// of older dates (the list's date column).
  String _date(DateTime when, {bool short = false}) {
    final local = when.toLocal();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(local.year, local.month, local.day);
    String two(int v) => v.toString().padLeft(2, '0');
    final time = '${two(local.hour)}:${two(local.minute)}';
    if (day == today) {
      return text.remoteFilesToday(time);
    }
    if (day == today.subtract(const Duration(days: 1))) {
      return text.remoteFilesYesterday(time);
    }
    final date = '${local.year}-${two(local.month)}-${two(local.day)}';
    return short ? date : '$date $time';
  }
}

/// One entry of a folder page.
class ShareRow {
  const ShareRow({
    required this.name,
    required this.isDir,
    required this.size,
    required this.modified,
    required this.href,
    required this.downloadHref,
  });

  final String name;
  final bool isDir;
  final int size;
  final DateTime modified;

  /// Where the name leads: the folder's page, or the file's page.
  final String href;
  final String downloadHref;
}

enum ShareMessage { notFound, missing, tooMany, error }

/// What a browser can show by itself.
enum SharePreview { image, video, audio, pdf, text }

const _imageExt = {
  'jpg',
  'jpeg',
  'png',
  'gif',
  'webp',
  'avif',
  'bmp',
  'ico',
  'svg',
};
const _videoExt = {'mp4', 'm4v', 'mov', 'webm', 'ogv'};
const _audioExt = {'mp3', 'm4a', 'aac', 'wav', 'ogg', 'oga', 'opus', 'flac'};
const _textExt = {'txt', 'log', 'md', 'csv'};

/// Plain text worth showing the start of on the file's page.
const shareTextPreviewExt = {
  'txt',
  'log',
  'md',
  'markdown',
  'csv',
  'tsv',
  'json',
  'yaml',
  'yml',
  'toml',
  'ini',
  'conf',
  'cfg',
  'xml',
  'html',
  'htm',
  'css',
  'js',
  'ts',
  'dart',
  'py',
  'java',
  'kt',
  'swift',
  'c',
  'h',
  'cc',
  'cpp',
  'hpp',
  'cs',
  'go',
  'rs',
  'rb',
  'php',
  'sh',
  'bat',
  'ps1',
  'sql',
  'srt',
  'vtt',
};

SharePreview? sharePreviewOf(String name) {
  final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
  if (_imageExt.contains(ext)) return SharePreview.image;
  if (_videoExt.contains(ext)) return SharePreview.video;
  if (_audioExt.contains(ext)) return SharePreview.audio;
  if (ext == 'pdf') return SharePreview.pdf;
  if (_textExt.contains(ext)) return SharePreview.text;
  return null;
}

/// Whether the file's page may show the start of [name] as text.
bool shareShowsText(String name) => shareTextPreviewExt.contains(
  p.extension(name).toLowerCase().replaceFirst('.', ''),
);

String _extension(String name) {
  final ext = p.extension(name);
  return ext.length > 1 && ext.length <= 6
      ? ext.substring(1).toUpperCase()
      : '';
}

String _size(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  const units = ['KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = -1;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

const _escape = HtmlEscape(HtmlEscapeMode.attribute);
String _e(String text) => _escape.convert(text);
String _a(String text) => _escape.convert(text);

/// The colour a file is known by: its kind's, with documents told apart
/// the way people know them (PDF red, sheets green, slides orange).
String _hueOf(String name) {
  final ext = p.extension(name).toLowerCase().replaceFirst('.', '');
  if (ext == 'pdf') return '#E5352B';
  if (const {'xls', 'xlsx', 'numbers', 'csv', 'tsv', 'ods'}.contains(ext)) {
    return '#1D9A49';
  }
  if (const {'ppt', 'pptx', 'key', 'odp'}.contains(ext)) return '#F0780A';
  return switch (fsKindOf(name)) {
    FsKind.folder => '#3A97EA',
    FsKind.image => '#1E9FBF',
    FsKind.video => '#9B4DD6',
    FsKind.audio => '#F02D5C',
    FsKind.document => '#2F7CF6',
    FsKind.archive => '#9A7752',
    FsKind.code => '#5856D6',
    FsKind.app => '#636366',
    FsKind.other => '#8E8E93',
  };
}

String _glyph(FsKind kind, String ext) {
  if (ext == 'pdf') {
    return '<path d="M6 4.5h8l4 4V19a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V5.5a1 1 0 0 1 1-1z" '
        'fill="none" stroke="currentColor" stroke-width="1.8" '
        'stroke-linejoin="round"/><path d="M8.5 12.5h7M8.5 15.5h5" '
        'stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>';
  }
  return switch (kind) {
    FsKind.image =>
      '<rect x="3.5" y="5" width="17" height="14" rx="3" fill="none" '
          'stroke="currentColor" stroke-width="1.8"/><circle cx="9" cy="10" '
          'r="1.8"/><path d="M5 17.5l4.6-4.6 3.2 3.2 2.2-2.2 4.5 3.6z"/>',
    FsKind.video =>
      '<path d="M8.2 5.6v12.8c0 .7.8 1.1 1.4.7l9.6-6.4a.85.85 0 0 0 0-1.4L9.6 '
          '4.9c-.6-.4-1.4 0-1.4.7z"/>',
    FsKind.audio =>
      '<path d="M18.5 3.4v11.4a3.1 3.1 0 1 1-1.9-2.86V7.7L9.9 9.1v7.7a3.1 '
          '3.1 0 1 1-1.9-2.86V6.5z"/>',
    FsKind.archive =>
      '<rect x="3.5" y="4.5" width="17" height="4.5" rx="1.4"/><path '
          'd="M5 10.5h14v7.5a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2z"/><rect x="9.5" '
          'y="12.5" width="5" height="1.8" rx=".9" fill="#fff"/>',
    FsKind.code =>
      '<path d="M8.5 7l-5 5 5 5M15.5 7l5 5-5 5" fill="none" '
          'stroke="currentColor" stroke-width="2.2" stroke-linecap="round" '
          'stroke-linejoin="round"/>',
    FsKind.app =>
      '<rect x="4.5" y="4.5" width="15" height="15" rx="4.2" fill="none" '
          'stroke="currentColor" stroke-width="1.9"/><path d="M12 8.5v7M8.5 '
          '12h7" stroke="currentColor" stroke-width="1.9" '
          'stroke-linecap="round"/>',
    _ =>
      '<rect x="5" y="6" width="14" height="1.9" rx=".95"/>'
          '<rect x="5" y="10" width="14" height="1.9" rx=".95"/>'
          '<rect x="5" y="14" width="14" height="1.9" rx=".95"/>'
          '<rect x="5" y="18" width="8.5" height="1.9" rx=".95"/>',
  };
}

/// A sheet of paper with a folded corner, the kind's glyph and, when the
/// file has one, a band with its extension.
String _fileIcon(String name) {
  final hue = _hueOf(name);
  final ext = _extension(name);
  final glyph = _glyph(
    fsKindOf(name),
    p.extension(name).toLowerCase().replaceFirst('.', ''),
  );
  const sheet = 'M13 3H40.5L55 17.5V57Q55 61 51 61H13Q9 61 9 57V7Q9 3 13 3Z';
  final band = ext.isEmpty
      ? ''
      : '<rect x="14" y="42.5" width="36" height="12.5" rx="3.2" '
            'fill="$hue"/>'
            '<text x="32" y="51.6" text-anchor="middle" font-size="'
            '${ext.length > 4 ? 7 : 8.4}" font-weight="700" '
            'letter-spacing=".3" fill="#fff" font-family="-apple-system,'
            'BlinkMacSystemFont,Segoe UI,Roboto,Helvetica,Arial,sans-serif">'
            '${_e(ext)}</text>';
  return '<svg viewBox="0 0 64 64" aria-hidden="true">'
      '<path d="$sheet" transform="translate(0 1)" fill="#000" '
      'fill-opacity=".08"/>'
      '<path class="paper" d="$sheet"/>'
      '<path class="fold" d="M40.5 3V14.5Q40.5 17.5 43.5 17.5H55Z"/>'
      '<g transform="translate(${ext.isEmpty ? 18.2 : 19.4} '
      '${ext.isEmpty ? 21 : 14.2}) scale(${ext.isEmpty ? 1.15 : 1.05})" '
      'fill="$hue" color="$hue">$glyph</g>'
      '$band</svg>';
}

String _folderIcon({bool outline = false}) => outline
    ? '<svg class="outline" viewBox="0 0 64 64" aria-hidden="true">'
          '<path d="M5 15.5Q5 12 8.5 12H24Q26.4 12 27.7 14.2L29 16.5H55.5Q59 '
          '16.5 59 20V50.5Q59 54 55.5 54H8.5Q5 54 5 50.5Z" fill="none" '
          'stroke="currentColor" stroke-width="2.2" stroke-linejoin="round"/>'
          '<path d="M5 23H59" stroke="currentColor" stroke-width="2.2"/></svg>'
    : '<svg viewBox="0 0 64 64" aria-hidden="true">'
          '<path class="fback" d="M3 14Q3 10.5 6.5 10.5H24Q26.6 10.5 28 13'
          'L29 15H57.5Q61 15 61 18.5V51.5Q61 55 57.5 55H6.5Q3 55 3 51.5Z"/>'
          '<rect x="3" y="20" width="58" height="35" rx="4" fill="url(#wsf)"/>'
          '<path d="M7 20.6H57" stroke="#fff" stroke-opacity=".45" '
          'stroke-width="1"/></svg>';

const _defs =
    '<svg width="0" height="0" style="position:absolute" aria-hidden="true">'
    '<defs><linearGradient id="wsf" x1="0" y1="0" x2="0" y2="1">'
    '<stop offset="0" class="f1"/><stop offset="1" class="f2"/>'
    '</linearGradient><linearGradient id="wsr" x1="0" y1="0" x2="1" y2="1">'
    '<stop offset="0" stop-color="#2b8fd6"/><stop offset="1" '
    'stop-color="#8cd33a"/></linearGradient></defs></svg>';

/// Whisper's mark: the app icon's ring, blue into green.
const _brandMark =
    '<svg class="mark" viewBox="0 0 24 24" aria-hidden="true"><circle '
    'cx="12" cy="12" r="9.4" fill="none" stroke="url(#wsr)" '
    'stroke-width="2.2"/><path d="M7.6 9.8l1.5 5.2 1.9-4.2 1.9 4.2 1.5-5.2" '
    'fill="none" stroke="currentColor" stroke-width="1.6" '
    'stroke-linecap="round" stroke-linejoin="round" opacity=".7"/></svg>';

String _deviceGlyph(String platform) => switch (platform) {
  'android' || 'ios' =>
    '<svg class="glyph" viewBox="0 0 24 24" aria-hidden="true"><rect x="7" '
        'y="2.8" width="10" height="18.4" rx="2.6" fill="none" '
        'stroke="currentColor" stroke-width="1.7"/><path d="M10.6 18h2.8" '
        'stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>'
        '</svg>',
  'macos' =>
    '<svg class="glyph" viewBox="0 0 24 24" aria-hidden="true"><rect x="4.5" '
        'y="5" width="15" height="10.5" rx="1.6" fill="none" '
        'stroke="currentColor" stroke-width="1.7"/><path d="M2.5 18.5h19" '
        'stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>'
        '</svg>',
  _ =>
    '<svg class="glyph" viewBox="0 0 24 24" aria-hidden="true"><rect x="3" '
        'y="4" width="18" height="12" rx="1.8" fill="none" '
        'stroke="currentColor" stroke-width="1.7"/><path d="M9 20h6M12 16v4" '
        'stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/>'
        '</svg>',
};

const _downloadGlyph =
    '<svg class="glyph" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 '
    '4.5v10.5M7.5 10.5L12 15l4.5-4.5M5.5 19.5h13" fill="none" '
    'stroke="currentColor" stroke-width="2" stroke-linecap="round" '
    'stroke-linejoin="round"/></svg>';

const _openGlyph =
    '<svg class="glyph" viewBox="0 0 24 24" aria-hidden="true"><path d="M13.5 '
    '5.5H18.5V10.5M18.5 5.5L11 13M10 6.5H7.5A2 2 0 0 0 5.5 8.5V16.5A2 2 0 0 0 '
    '7.5 18.5H15.5A2 2 0 0 0 17.5 16.5V14" fill="none" stroke="currentColor" '
    'stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>'
    '</svg>';

const _chevronGlyph =
    '<svg class="glyph" viewBox="0 0 24 24" aria-hidden="true"><path d="M9.5 '
    '6l6 6-6 6" fill="none" stroke="currentColor" stroke-width="2" '
    'stroke-linecap="round" stroke-linejoin="round"/></svg>';

const _backGlyph =
    '<svg class="glyph" viewBox="0 0 24 24" aria-hidden="true"><path d="M14.5 '
    '6l-6 6 6 6" fill="none" stroke="currentColor" stroke-width="2" '
    'stroke-linecap="round" stroke-linejoin="round"/></svg>';

const _homeGlyph =
    '<svg class="glyph" viewBox="0 0 24 24" aria-hidden="true"><path d="M4.5 '
    '11L12 4.5 19.5 11M6.5 9.5V19h4v-5h3v5h4V9.5" fill="none" '
    'stroke="currentColor" stroke-width="1.8" stroke-linecap="round" '
    'stroke-linejoin="round"/></svg>';

const _lockGlyph =
    '<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="5" y="10.5" '
    'width="14" height="10" rx="2.6" fill="currentColor"/><path d="M8.2 '
    '10.5V8a3.8 3.8 0 0 1 7.6 0v2.5" fill="none" stroke="currentColor" '
    'stroke-width="2"/></svg>';

const _keyGlyph =
    '<svg class="glyph" viewBox="0 0 24 24" aria-hidden="true"><circle '
    'cx="8" cy="12" r="3.6" fill="none" stroke="currentColor" '
    'stroke-width="1.8"/><path d="M11.6 12H20M17 12v3M20 12v2.5" fill="none" '
    'stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>';

const _alertGlyph =
    '<svg class="glyph" viewBox="0 0 24 24" aria-hidden="true"><circle '
    'cx="12" cy="12" r="9" fill="currentColor"/><path d="M12 7.5v5.5" '
    'stroke="#fff" stroke-width="2" stroke-linecap="round"/><circle cx="12" '
    'cy="16.3" r="1.2" fill="#fff"/></svg>';

const _shieldGlyph =
    '<svg class="glyph" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 '
    '3.5l7 2.6v5.4c0 4.4-2.9 7.6-7 9-4.1-1.4-7-4.6-7-9V6.1z" fill="none" '
    'stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"/>'
    '<path d="M9 12l2.1 2.1L15.2 10" fill="none" stroke="currentColor" '
    'stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>'
    '</svg>';

const _linkOffGlyph =
    '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M10 14a4 4 0 0 0 '
    '5.6.2l3-3a4 4 0 0 0-5.6-5.7l-1.1 1.1M14 10a4 4 0 0 0-5.6-.2l-3 3a4 4 0 '
    '0 0 5.6 5.7l1.1-1.1" fill="none" stroke="currentColor" '
    'stroke-width="1.8" stroke-linecap="round"/><path d="M4 4l16 16" '
    'stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>';

const _questionGlyph =
    '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" '
    'r="9" fill="none" stroke="currentColor" stroke-width="1.8"/><path '
    'd="M9.4 9.4a2.7 2.7 0 1 1 3.9 2.4c-.8.4-1.3 1-1.3 1.9v.4" fill="none" '
    'stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/>'
    '<circle cx="12" cy="17" r="1.1" fill="currentColor"/></svg>';

const _clockGlyph =
    '<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" '
    'r="9" fill="none" stroke="currentColor" stroke-width="1.8"/><path '
    'd="M12 7v5l3.2 2" fill="none" stroke="currentColor" stroke-width="1.8" '
    'stroke-linecap="round" stroke-linejoin="round"/></svg>';

const _warningGlyph =
    '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M10.3 4.2a2 2 0 0 '
    '1 3.4 0l7.4 12.8A2 2 0 0 1 19.4 20H4.6a2 2 0 0 1-1.7-3z" fill="none" '
    'stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/><path '
    'd="M12 9.5v4" stroke="currentColor" stroke-width="1.8" '
    'stroke-linecap="round"/><circle cx="12" cy="16.6" r="1.05" '
    'fill="currentColor"/></svg>';

final _favicon =
    'data:image/svg+xml,${Uri.encodeComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2b8fd6"/><stop offset="1" stop-color="#8cd33a"/></linearGradient></defs><circle cx="32" cy="32" r="27" fill="#fff" stroke="url(#g)" stroke-width="6"/><path d="M32 20v19M23.5 31l8.5 8.5 8.5-8.5" fill="none" stroke="#2b8fd6" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/></svg>')}';

const _css = '''
:root{color-scheme:light dark;--bg:#f5f5f7;--card:#fff;--raised:#fbfbfd;--label:#1d1d1f;--secondary:#6e6e73;--tertiary:#aeaeb2;--hair:rgba(0,0,0,.08);--hair2:rgba(0,0,0,.12);--accent:#0071e3;--accent-hover:#0077ed;--accent-press:#006edb;--link:#0066cc;--tint:rgba(0,113,227,.08);--tint2:rgba(0,113,227,.14);--hover:rgba(0,0,0,.035);--press:rgba(0,0,0,.065);--field:#fff;--field-line:rgba(0,0,0,.16);--danger:#d70015;--warn:#b25000;--bar:rgba(245,245,247,.78);--stage:#f2f2f5;--paper1:#fff;--paper2:#f3f3f6;--paper-line:rgba(0,0,0,.14);--fold:#e4e4ea;--fback:#3a97ea;--f1:#7dc2fa;--f2:#4ba5f2;--shadow:0 1px 2px rgba(0,0,0,.04),0 10px 30px rgba(0,0,0,.07);--focus:rgba(0,113,227,.45)}
@media (prefers-color-scheme:dark){:root{--bg:#000;--card:#1c1c1e;--raised:#2c2c2e;--label:#f5f5f7;--secondary:#a1a1a6;--tertiary:#636366;--hair:rgba(255,255,255,.1);--hair2:rgba(255,255,255,.16);--link:#2997ff;--tint:rgba(41,151,255,.14);--tint2:rgba(41,151,255,.22);--hover:rgba(255,255,255,.055);--press:rgba(255,255,255,.1);--field:#2c2c2e;--field-line:rgba(255,255,255,.18);--danger:#ff453a;--warn:#ff9f0a;--bar:rgba(22,22,23,.78);--stage:#111113;--paper1:#efeff3;--paper2:#dcdce2;--paper-line:rgba(0,0,0,.45);--fold:#c9c9d1;--fback:#2b80d3;--f1:#5daef4;--f2:#358bdd;--shadow:0 0 0 .5px rgba(255,255,255,.08);--focus:rgba(41,151,255,.6)}}
@media (prefers-contrast:more){:root{--hair:rgba(0,0,0,.28);--secondary:#48484a}}
*{box-sizing:border-box}
html{-webkit-text-size-adjust:100%;text-size-adjust:100%}
body{margin:0;min-height:100vh;min-height:100dvh;display:flex;flex-direction:column;background:var(--bg);color:var(--label);font:17px/1.47 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI Variable Text","Segoe UI",system-ui,Roboto,"Helvetica Neue","PingFang SC","Hiragino Sans GB","Microsoft YaHei UI","Microsoft YaHei","Noto Sans CJK SC",sans-serif;-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale}
a{color:var(--link);text-decoration:none}
.glyph{width:20px;height:20px;flex:none}
:focus-visible{outline:3px solid var(--focus);outline-offset:2px;border-radius:12px}
.bar{position:sticky;top:0;z-index:5;background:var(--bar);-webkit-backdrop-filter:saturate(180%) blur(20px);backdrop-filter:saturate(180%) blur(20px);border-bottom:.5px solid var(--hair)}
.bar-in{max-width:960px;margin:0 auto;height:52px;padding:0 max(16px,env(safe-area-inset-right)) 0 max(16px,env(safe-area-inset-left));display:flex;align-items:center;justify-content:space-between;gap:12px}
.bar-in.wide{max-width:1120px}
.brand{display:flex;align-items:center;gap:8px;font-size:17px;font-weight:600;letter-spacing:-.01em;color:var(--label)}
.mark{width:24px;height:24px;flex:none;color:var(--label)}
.device{display:flex;align-items:center;gap:6px;min-width:0;padding:5px 12px 5px 9px;border-radius:980px;background:var(--hover);color:var(--secondary);font-size:14px}
.device span{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.device .glyph{width:17px;height:17px}
.wrap{width:100%;max-width:960px;margin:0 auto;padding:24px max(16px,env(safe-area-inset-right)) 8px max(16px,env(safe-area-inset-left));flex:1}
.wrap.mid{max-width:600px}
.wrap.narrow{max-width:460px}
.wrap.wide{max-width:1120px}
.wrap.center{display:flex;flex-direction:column;justify-content:center}
.card{background:var(--card);border-radius:22px;box-shadow:var(--shadow)}
h1{margin:0;font-weight:700;letter-spacing:-.022em;overflow-wrap:anywhere}
.crumbs{margin:0 0 16px;font-size:15px}
.crumbs .up{display:inline-flex;align-items:center;gap:2px;margin-left:-6px;padding:6px 10px 6px 4px;border-radius:980px;max-width:100%}
.crumbs .up span{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.crumbs .path{display:none;list-style:none;margin:0;padding:0;flex-wrap:wrap;align-items:center}
.crumbs .path li{display:flex;align-items:center;min-width:0}
.crumbs .path a{display:flex;align-items:center;gap:6px;padding:5px 10px;border-radius:980px;color:var(--secondary);max-width:280px}
.crumbs .path a span{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.crumbs .path a .glyph{width:17px;height:17px}
.crumbs .path i{display:flex;color:var(--tertiary)}
.crumbs .path i .glyph{width:14px;height:14px}
.crumbs a:hover{background:var(--hover);color:var(--label)}
.crumbs .here{display:block;padding:5px 10px;color:var(--label);font-weight:600;max-width:280px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.head{display:grid;grid-template-columns:auto 1fr;align-items:center;gap:6px 16px;margin:4px 0 22px}
.head-icon{width:60px;height:60px}
.head-icon svg{width:100%;height:100%;display:block}
.head h1{font-size:28px;line-height:1.15}
.meta{margin:4px 0 0;color:var(--secondary);font-size:15px;font-variant-numeric:tabular-nums}
.head .btn{grid-column:1/-1;margin-top:12px}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:8px;min-height:44px;padding:0 20px;border:0;border-radius:980px;font:inherit;font-size:16px;font-weight:600;letter-spacing:-.01em;cursor:pointer;white-space:nowrap;-webkit-tap-highlight-color:transparent;transition:background-color .15s,transform .1s,box-shadow .15s}
.btn:active{transform:scale(.98)}
.btn.primary{background:var(--accent);color:#fff;box-shadow:0 1px 2px rgba(0,0,0,.1)}
.btn.primary:hover{background:var(--accent-hover)}
.btn.primary:active{background:var(--accent-press)}
.btn.secondary{background:var(--tint);color:var(--link)}
.btn.secondary:hover{background:var(--tint2)}
.btn.ghost{background:transparent;color:var(--link);padding:0 12px;min-height:40px;font-weight:500}
.btn.ghost:hover{background:var(--hover)}
.btn.ghost.off{color:var(--tertiary);cursor:default}
.btn.ghost.off:hover{background:transparent}
.btn.ghost.off:active{transform:none}
.btn.big{min-height:52px;font-size:17px;width:100%}
.btn .size{font-weight:400;opacity:.78;font-variant-numeric:tabular-nums}
.btn .size::before{content:"·";margin-right:8px}
.btn:focus-visible{border-radius:980px}
.table{overflow:hidden}
.thead{display:none}
.rows{list-style:none;margin:0;padding:0}
.row{display:grid;grid-template-columns:minmax(0,1fr) 56px;align-items:center;position:relative}
.row+.row::before{content:"";position:absolute;top:0;left:70px;right:0;border-top:.5px solid var(--hair)}
.c-name{display:flex;align-items:center;gap:14px;min-width:0;min-height:64px;padding:10px 4px 10px 16px;color:inherit;-webkit-tap-highlight-color:transparent}
.icon{width:40px;height:40px;flex:none}
.icon svg{width:100%;height:100%;display:block}
.names{display:flex;flex-direction:column;min-width:0}
.n{font-size:16px;font-weight:500;line-height:1.3;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sub{margin-top:2px;font-size:13px;color:var(--secondary);font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.c-date,.c-size{display:none}
.c-act{display:flex;align-items:center;justify-content:center;align-self:stretch;color:var(--link);-webkit-tap-highlight-color:transparent}
.c-act .glyph{width:22px;height:22px;padding:7px;box-sizing:content-box;border-radius:50%;transition:background-color .15s}
.c-act.go{color:var(--tertiary)}
.c-act.go .glyph{width:16px;height:16px}
.c-act.dl:hover .glyph{background:var(--tint)}
.row:hover{background:var(--hover)}
.row:active{background:var(--press)}
.empty{display:flex;flex-direction:column;align-items:center;gap:12px;padding:48px 24px;color:var(--secondary)}
.empty .outline{width:64px;height:64px;color:var(--tertiary)}
.empty p{margin:0}
.file{overflow:hidden}
.stage{position:relative;display:flex;flex-direction:column;align-items:center;justify-content:center;background:var(--stage);min-height:220px}
.stage.plain,.stage.sound{background:radial-gradient(120% 90% at 50% 0%,var(--card) 0%,var(--stage) 75%)}
.icon-hero{width:132px;height:132px}
.icon-hero svg{width:100%;height:100%;display:block;filter:drop-shadow(0 6px 14px rgba(0,0,0,.12))}
.stage.photo{background:var(--stage)}
.stage.photo img{display:block;max-width:100%;max-height:min(72vh,860px);object-fit:contain}
.stage.movie{background:#000}
.stage.movie video{display:block;width:100%;max-height:min(70vh,820px);background:#000}
.stage.sound{padding:28px 20px 22px;gap:22px}
.stage.sound audio{width:100%;max-width:420px}
.stage.text{align-items:stretch;justify-content:flex-start;min-height:0;padding:0;background:var(--raised)}
.file.textual{display:flex;flex-direction:column}
.file.textual .info{order:-1;border-bottom:.5px solid var(--hair)}
.stage.text pre{margin:0;padding:18px 20px;max-height:min(56vh,640px);overflow:auto;font:13px/1.55 ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,"Liberation Mono",monospace;color:var(--label);white-space:pre-wrap;overflow-wrap:anywhere;tab-size:4}
.note{margin:0;padding:10px 20px 12px;border-top:.5px solid var(--hair);font-size:13px;color:var(--secondary)}
.info{padding:22px 20px 20px}
.file-name{font-size:24px;line-height:1.22}
.facts{display:flex;flex-wrap:wrap;align-items:center;gap:6px 14px;margin:10px 0 0;color:var(--secondary);font-size:14px;font-variant-numeric:tabular-nums}
.chip{display:inline-flex;align-items:center;gap:7px;padding:3px 10px 3px 8px;border-radius:980px;background:var(--hover);color:var(--label);font-size:13px;font-weight:500}
.chip i{width:8px;height:8px;border-radius:50%}
.actions{display:flex;flex-direction:column;gap:10px;margin-top:22px}
.pager{display:flex;align-items:center;justify-content:space-between;gap:8px;margin:18px -8px 0;padding-top:12px;border-top:.5px solid var(--hair)}
.pager .count{color:var(--secondary);font-size:14px;font-variant-numeric:tabular-nums}
.panel{padding:36px 24px 26px;text-align:center}
.panel h1{font-size:24px;line-height:1.22}
.lead{margin:8px auto 0;max-width:30em;color:var(--secondary);font-size:16px}
.badge{width:76px;height:76px;margin:0 auto 18px;border-radius:50%;display:flex;align-items:center;justify-content:center}
.badge svg{width:36px;height:36px}
.badge.accent{background:var(--tint);color:var(--link)}
.badge.muted{background:var(--hover);color:var(--secondary)}
.badge.warn{background:rgba(255,159,10,.14);color:var(--warn)}
.badge.danger{background:rgba(255,69,58,.12);color:var(--danger)}
.panel .actions{margin-top:26px}
.form{display:flex;flex-direction:column;gap:12px;margin-top:26px;text-align:left}
.field{display:flex;align-items:center;gap:10px;height:52px;padding:0 16px;border-radius:14px;border:1px solid var(--field-line);background:var(--field);color:var(--secondary);transition:border-color .15s,box-shadow .15s}
.field:focus-within{border-color:var(--accent);box-shadow:0 0 0 4px var(--tint2)}
.field.invalid{border-color:var(--danger)}
.field.invalid:focus-within{box-shadow:0 0 0 4px rgba(255,59,48,.16)}
.field input{flex:1;min-width:0;height:100%;border:0;outline:0;background:transparent;color:var(--label);font:inherit;font-size:17px}
.error{display:flex;align-items:center;gap:8px;margin:0 2px;color:var(--danger);font-size:14px}
.error .glyph{width:17px;height:17px}
footer{padding:28px 24px calc(24px + env(safe-area-inset-bottom));text-align:center;font-size:13px;color:var(--secondary)}
footer p{max-width:36em;margin:0 auto}
footer .glyph{display:inline-block;width:15px;height:15px;margin:0 6px -3px 0;color:var(--tertiary)}
.paper{fill:var(--paper1);stroke:var(--paper-line);stroke-width:1}
.fold{fill:var(--fold);stroke:var(--paper-line);stroke-width:1;stroke-linejoin:round}
.fback{fill:var(--fback)}
.f1{stop-color:var(--f1)}
.f2{stop-color:var(--f2)}
@media (min-width:600px){.wrap{padding-top:40px}.panel{padding:44px 40px 32px}.actions{flex-direction:row}.actions .btn{flex:1}.info{padding:26px 28px 24px}}
@media (min-width:760px){.crumbs .up{display:none}.crumbs .path{display:flex}.head{grid-template-columns:auto 1fr auto}.head .btn{grid-column:auto;margin-top:0}.thead{display:grid;grid-template-columns:minmax(0,1fr) 170px 100px 64px;padding:12px 0 8px 70px;border-bottom:.5px solid var(--hair);font-size:12px;font-weight:600;color:var(--secondary);letter-spacing:.01em}.thead .c-size{text-align:right;display:block}.thead .c-date{display:block}.row{grid-template-columns:minmax(0,1fr) 170px 100px 64px}.row .c-date,.row .c-size{display:block;font-size:14px;color:var(--secondary);font-variant-numeric:tabular-nums;white-space:nowrap}.row .c-size{text-align:right}.sub{display:none}.c-name{min-height:56px}.row+.row::before{left:70px}}
@media (min-width:1000px){.file.media{display:grid;grid-template-columns:minmax(0,1fr) 380px;align-items:stretch}.file.media .stage.photo{min-height:420px}.file.media .info{display:flex;flex-direction:column;border-left:.5px solid var(--hair)}.file.media .actions{flex-direction:column}.file.media .pager{margin-top:auto}}
@media (prefers-reduced-motion:reduce){.btn{transition:none}.btn:active{transform:none}}
''';
