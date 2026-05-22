import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop file messages expose copy-only native drag source', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    const dragSourcePath = 'lib/widget/desktop_file_drag_source.dart';
    final conversation = File('lib/page/conversation.dart').readAsStringSync();

    expect(pubspec, contains('super_drag_and_drop:'));
    expect(File(dragSourcePath).existsSync(), isTrue);

    final dragSource = File(dragSourcePath).readAsStringSync();
    expect(dragSource, contains('DragItemWidget'));
    expect(dragSource, contains('DraggableWidget'));
    expect(dragSource, contains('DropOperation.copy'));
    expect(dragSource, contains('Formats.fileUri(Uri.file(path))'));
    expect(dragSource, contains('isDesktop()'));
    expect(dragSource, contains('File(path).existsSync()'));

    expect(conversation, contains('DesktopFileDragSource('));
    expect(conversation, contains('enabled: _canDragFileMessage('));
  });
}
