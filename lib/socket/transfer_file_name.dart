import 'dart:convert';

const int maxIncomingFileNameBytes = 240;

final RegExp _windowsReservedName = RegExp(
  r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$',
  caseSensitive: false,
);
const Set<int> _windowsInvalidCharacters = <int>{
  0x3c,
  0x3e,
  0x3a,
  0x22,
  0x7c,
  0x3f,
  0x2a,
};
bool validateIncomingFileName(String fileName) {
  if (fileName.isEmpty ||
      !_hasWellFormedUtf16(fileName) ||
      utf8.encode(fileName).length > maxIncomingFileNameBytes ||
      fileName == '.' ||
      fileName == '..' ||
      fileName.endsWith('.') ||
      fileName.endsWith(' ') ||
      fileName.contains('/') ||
      fileName.contains('\\')) {
    return false;
  }
  for (final rune in fileName.runes) {
    if (isFileNameControl(rune) || _windowsInvalidCharacters.contains(rune)) {
      return false;
    }
  }
  final portableStem = fileName.split('.').first;
  return !_windowsReservedName.hasMatch(portableStem);
}

/// C0 and C1 controls, and the bidi embeddings, overrides and isolates
/// (U+202A–U+202E, U+2066–U+2069): those make `Invoice\u202excod.exe` show
/// as `Invoiceexe.docx`, in the chat and in the file manager, for a program
/// that opens with a click. Never part of a name from another device.
bool isFileNameControl(int rune) =>
    rune <= 0x1f ||
    (rune >= 0x7f && rune <= 0x9f) ||
    (rune >= 0x202a && rune <= 0x202e) ||
    (rune >= 0x2066 && rune <= 0x2069);

bool _hasWellFormedUtf16(String value) {
  final units = value.codeUnits;
  for (var index = 0; index < units.length; index += 1) {
    final unit = units[index];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (index + 1 >= units.length) {
        return false;
      }
      final next = units[++index];
      if (next < 0xdc00 || next > 0xdfff) {
        return false;
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}
