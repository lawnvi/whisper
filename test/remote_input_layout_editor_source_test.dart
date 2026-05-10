import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('layout editor refreshes remote topology after the route opens', () {
    final source = File('lib/remote_input/remote_input_layout_editor.dart')
        .readAsStringSync();

    expect(source, contains('RemoteInputTopologyLoader'));
    expect(source, contains('remoteTopologyLoader'));
    expect(source, contains('unawaited(_loadRemoteTopology())'));
    expect(source, contains('Future<void> _loadRemoteTopology()'));
    expect(source, contains('await widget.remoteTopologyLoader?.call()'));
    expect(source, contains('topology != null && topology.isNotEmpty'));
  });
}
