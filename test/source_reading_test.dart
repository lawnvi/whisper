import 'package:flutter_test/flutter_test.dart';

import 'support/source_reading.dart';

void main() {
  const code = r'''
class A {
  // a comment with a } brace
  void one({required int a}) {
    final s = 'a } b ${a + {1}.length} "c" }';
    if (a > 0) {
      print(s);
    }
  }

  int two() => [1, 2].length;

  final map = <String, int>{'}': 1};

  String three() {
    return r'\}';
  }
}
''';

  test('finds a member whatever follows it', () {
    expect(
      memberSource(code, 'void one('),
      allOf(startsWith('void one('), endsWith('print(s);\n    }\n  }')),
    );
    expect(memberSource(code, 'int two()'), 'int two() => [1, 2].length;');
    expect(memberSource(code, 'final map'), startsWith('final map'));
    expect(memberSource(code, 'String three()'), endsWith("r'\\}';\n  }"));
  });

  test('a missing member is an error, not an empty match', () {
    expect(() => memberSource(code, 'void four('), throwsStateError);
  });

  test('reads the device list wherever it lives', () {
    expect(deviceListSource(), contains('class DeviceListScreen'));
    expect(readSource('lib/page/deviceList.dart'), deviceListSource());
    expect(readSource('pubspec.yaml'), contains('name: whisper'));
  });
}
