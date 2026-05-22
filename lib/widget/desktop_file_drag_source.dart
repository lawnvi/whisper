import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:whisper/helper/helper.dart';

class DesktopFileDragSource extends StatelessWidget {
  const DesktopFileDragSource({
    super.key,
    required this.path,
    required this.name,
    required this.enabled,
    required this.child,
  });

  final String path;
  final String name;
  final bool enabled;
  final Widget child;

  bool get _canDrag {
    return enabled && isDesktop() && path.isNotEmpty && File(path).existsSync();
  }

  @override
  Widget build(BuildContext context) {
    if (!_canDrag) {
      return child;
    }

    return DragItemWidget(
      allowedOperations: () => [DropOperation.copy],
      dragItemProvider: (_) async {
        if (!File(path).existsSync()) {
          return null;
        }
        final item = DragItem(
          suggestedName: name.isNotEmpty ? name : p.basename(path),
          localData: <String, String>{'path': path},
        );
        item.add(Formats.fileUri(Uri.file(path)));
        return item;
      },
      child: DraggableWidget(child: child),
    );
  }
}
