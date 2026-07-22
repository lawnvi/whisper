import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('transfer notices are delivered to one primary listener', () {
    final source = File('lib/socket/svrmanager.dart').readAsStringSync();

    expect(
      source,
      contains(
        'notify: (message) => '
        '_dispatchToPrimary((event) => event.onNotice(message))',
      ),
    );
  });
}
