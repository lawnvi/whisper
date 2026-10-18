import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the iOS database lives out of the Files app, moved there once', () {
    final source = File('lib/model/LocalDatabase.dart').readAsStringSync();
    final start = source.indexOf('Future<Directory> _databaseDirectory()');
    expect(start, isNonNegative);
    final body = source.substring(start, source.indexOf('\n}\n', start));
    final ios = body.substring(body.indexOf('if (Platform.isIOS)'));
    expect(ios, contains('getApplicationSupportDirectory()'));
    expect(ios, contains('migrateLegacyMacOSDatabase('));
    // The copy in Documents (and its journal) goes once it has moved.
    expect(ios, contains("const ['', '-wal', '-shm']"));
  });
}
