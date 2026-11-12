import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:mime/mime.dart';

// HTTP details the share link server and web transfer both need, none of
// which depend on a particular request's route.

String shareMimeOf(String name) =>
    lookupMimeType(name.toLowerCase()) ?? 'application/octet-stream';

/// Types a browser would run script in when opened directly.
bool shareIsActive(String mime, String name) {
  final lower = mime.toLowerCase();
  return lower.contains('html') ||
      lower.contains('xml') ||
      lower.contains('svg') ||
      lower.contains('javascript') ||
      lower.contains('ecmascript') ||
      name.toLowerCase().endsWith('.svgz');
}

/// [mime] with a charset where a browser would otherwise guess one.
String shareContentType(String mime) {
  if (mime.startsWith('text/') ||
      mime == 'application/json' ||
      mime == 'application/javascript') {
    return '$mime; charset=utf-8';
  }
  return mime;
}

/// `attachment` (or `inline`) with an ASCII fallback name and the real one
/// in RFC 5987 form, so every browser saves it under its own name.
String shareContentDisposition(String name, {bool inline = false}) {
  final fallback = StringBuffer();
  for (final rune in name.runes) {
    final ok =
        rune >= 0x20 &&
        rune < 0x7f &&
        rune != 0x22 &&
        rune != 0x5c &&
        rune != 0x25;
    fallback.writeCharCode(ok ? rune : 0x5f);
  }
  final encoded = StringBuffer();
  for (final byte in utf8.encode(name)) {
    final c = String.fromCharCode(byte);
    final unreserved = RegExp(r"[A-Za-z0-9!#$&+.^_`|~-]").hasMatch(c);
    encoded.write(
      unreserved
          ? c
          : '%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}',
    );
  }
  return '${inline ? 'inline' : 'attachment'}; filename="$fallback"; '
      "filename*=UTF-8''$encoded";
}

/// Whether a request's `Host` names this device the way a LAN visitor
/// would: an address, `localhost`, a single-label or `.local` / `.lan` /
/// `.home.arpa` name. A public name that resolves here is a web page
/// trying to read the LAN through someone's browser.
bool shareHostAllowed(String? header) {
  if (header == null || header.isEmpty) {
    return true;
  }
  var host = header.trim().toLowerCase();
  if (host.startsWith('[')) {
    final end = host.indexOf(']');
    return end > 0 && InternetAddress.tryParse(host.substring(1, end)) != null;
  }
  final colon = host.lastIndexOf(':');
  if (colon >= 0) {
    host = host.substring(0, colon);
  }
  if (host.endsWith('.')) {
    host = host.substring(0, host.length - 1);
  }
  if (InternetAddress.tryParse(host) != null) {
    return true;
  }
  return host == 'localhost' ||
      !host.contains('.') ||
      host.endsWith('.local') ||
      host.endsWith('.lan') ||
      host.endsWith('.home.arpa') ||
      host.endsWith('.localdomain');
}

/// The value of cookie [name] in `Cookie` request headers, read leniently.
String? shareCookieValue(List<String>? headers, String name) {
  if (headers == null) {
    return null;
  }
  for (final header in headers) {
    for (final part in header.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      if (part.substring(0, eq).trim() == name) {
        var value = part.substring(eq + 1).trim();
        if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
          value = value.substring(1, value.length - 1);
        }
        return value;
      }
    }
  }
  return null;
}

/// The page language for an `Accept-Language` header: the most wanted of
/// Chinese, English and Spanish, else English.
Locale shareLocaleFor(String? header) {
  if (header == null || header.trim().isEmpty) {
    return const Locale('en');
  }
  final options = <(String, double, int)>[];
  var index = 0;
  for (final part in header.split(',')) {
    final pieces = part.trim().split(';');
    final tag = pieces.first.trim().toLowerCase();
    var quality = 1.0;
    for (final parameter in pieces.skip(1)) {
      final trimmed = parameter.trim();
      if (trimmed.startsWith('q=')) {
        quality = double.tryParse(trimmed.substring(2)) ?? 0;
      }
    }
    if (tag.isNotEmpty && quality > 0) {
      options.add((tag, quality, index++));
    }
  }
  options.sort((a, b) {
    final byQuality = b.$2.compareTo(a.$2);
    return byQuality != 0 ? byQuality : a.$3.compareTo(b.$3);
  });
  for (final (tag, _, _) in options) {
    final language = tag.split('-').first;
    if (language == 'zh' || language == 'en' || language == 'es') {
      return Locale(language);
    }
  }
  return const Locale('en');
}

/// Whether the client's copy (by `If-None-Match` or `If-Modified-Since`) is
/// still current.
bool shareNotModified(HttpRequest request, String etag, DateTime modified) {
  final match = request.headers.value('if-none-match');
  if (match != null) {
    return match
        .split(',')
        .map((tag) => tag.trim())
        .any((tag) => tag == '*' || tag == etag || tag == 'W/$etag');
  }
  final since = request.headers.ifModifiedSince;
  if (since != null) {
    return modified.millisecondsSinceEpoch ~/ 1000 <=
        since.millisecondsSinceEpoch ~/ 1000;
  }
  return false;
}

/// Whether an `If-Range` value still names this version of the file.
bool shareIfRangeMatches(String value, String etag, DateTime modified) {
  final trimmed = value.trim();
  if (trimmed.startsWith('"') || trimmed.startsWith('W/')) {
    return trimmed == etag;
  }
  try {
    final date = HttpDate.parse(trimmed);
    return modified.millisecondsSinceEpoch ~/ 1000 ==
        date.millisecondsSinceEpoch ~/ 1000;
  } on HttpException {
    return false;
  }
}

/// The start of a text file for its page: up to [limit] bytes decoded as
/// UTF-8, and whether there was more. Null for anything that looks binary
/// (a NUL early on) or cannot be read.
Future<(String, bool)?> shareTextSnippet(
  String path, {
  int limit = 32768,
}) async {
  RandomAccessFile? file;
  try {
    file = await File(path).open();
    final bytes = await file.read(limit + 1);
    final probe = bytes.length < 8192 ? bytes.length : 8192;
    for (var i = 0; i < probe; i++) {
      if (bytes[i] == 0) {
        return null;
      }
    }
    final truncated = bytes.length > limit;
    var text = utf8.decode(
      truncated ? bytes.sublist(0, limit) : bytes,
      allowMalformed: true,
    );
    if (text.startsWith('\uFEFF')) {
      text = text.substring(1);
    }
    if (truncated) {
      // A character cut in two at the end decodes as U+FFFD.
      while (text.endsWith('\uFFFD')) {
        text = text.substring(0, text.length - 1);
      }
    }
    return (text, truncated);
  } on FileSystemException {
    return null;
  } finally {
    await file?.close();
  }
}
