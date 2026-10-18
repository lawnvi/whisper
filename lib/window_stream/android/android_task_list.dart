import 'dart:convert';

class AndroidTask {
  const AndroidTask({
    required this.taskId,
    required this.packageName,
    required this.component,
    required this.displayId,
    required this.visible,
  });

  final int taskId;
  final String packageName;

  /// Base activity, `package/activity`.
  final String component;
  final int displayId;
  final bool visible;
}

/// Parses `am stack list`: root-task lines carry the display, the indented
/// task lines below them carry the task id and its base component.
abstract final class AndroidTaskList {
  static final _rootTask = RegExp(r'^RootTask id=\d+ .*displayId=(\d+)');
  static final _task = RegExp(r'^\s+taskId=(\d+): (([^/\s]+)/\S+)');

  static List<AndroidTask> parse(String output) {
    final tasks = <AndroidTask>[];
    final seen = <int>{};
    var displayId = 0;
    for (final line in const LineSplitter().convert(output)) {
      final root = _rootTask.firstMatch(line);
      if (root != null) {
        displayId = int.parse(root.group(1)!);
        continue;
      }
      final task = _task.firstMatch(line);
      if (task == null) {
        continue;
      }
      final id = int.parse(task.group(1)!);
      if (!seen.add(id)) {
        continue;
      }
      tasks.add(
        AndroidTask(
          taskId: id,
          packageName: task.group(3)!,
          component: task.group(2)!,
          displayId: displayId,
          visible: line.contains('visible=true'),
        ),
      );
    }
    return tasks;
  }

  static final _displayHeader = RegExp(r'^Display #(\d+)');
  static final _taskHeader = RegExp(r'^\s+\* Task\{\S+ #(\d+) type=(\w+)');

  /// Front task of [displayId] from `dumpsys activity activities` (tasks are
  /// listed top to bottom). Returns null when the display has none.
  static AndroidFrontTask? parseFrontTask(String dumpsys, {int displayId = 0}) {
    var inDisplay = false;
    for (final line in const LineSplitter().convert(dumpsys)) {
      final header = _displayHeader.firstMatch(line);
      if (header != null) {
        if (inDisplay) {
          return null;
        }
        inDisplay = int.parse(header.group(1)!) == displayId;
        continue;
      }
      if (!inDisplay) {
        continue;
      }
      final task = _taskHeader.firstMatch(line);
      if (task != null) {
        return AndroidFrontTask(
          taskId: int.parse(task.group(1)!),
          isHome: task.group(2) == 'home',
        );
      }
    }
    return null;
  }
}

class AndroidFrontTask {
  const AndroidFrontTask({required this.taskId, required this.isHome});

  final int taskId;
  final bool isHome;
}
