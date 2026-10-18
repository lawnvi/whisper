import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:super_clipboard/super_clipboard.dart'
    show
        SimpleFileFormat,
        VirtualFileEventSinkProvider,
        VirtualFileStorage,
        WriteProgress;
import 'package:super_clipboard/super_clipboard_internal.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:super_native_extensions/raw_drag_drop.dart' as raw;

import '../../remote_files/files_log.dart';
import 'files_model.dart';

/// What is dragged around inside the file manager.
class FilesDragData {
  const FilesDragData(this.items);

  final List<FilesItem> items;
}

/// Items are dragged in a system drag, which can leave the window: Finder
/// and Explorer take this device's files as they are, and another device's
/// files as they are fetched once dropped. Linux has no way to hand over a
/// file that is still to be fetched, so there the drag stays in the window.
bool get filesSystemDrag =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows);

/// Starts a drag once the pointer has moved a little, however long the
/// button was held first.
class FilesSlopDragRecognizer extends MultiDragGestureRecognizer {
  FilesSlopDragRecognizer() : super(debugOwner: null);

  /// How far the pointer moves before it is a drag.
  static const double slop = 6;

  /// The pointer of the latest drag.
  int? pointer;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    pointer = event.pointer;
    super.addAllowedPointer(event);
  }

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      _SlopPointerState(event.position, event.kind, gestureSettings);

  @override
  String get debugDescription => 'files drag';
}

class _SlopPointerState extends MultiDragPointerState {
  _SlopPointerState(
    super.initialPosition,
    super.kind,
    super.deviceGestureSettings,
  );

  /// Won, but not moved far enough yet to start.
  GestureMultiDragStartCallback? _starter;

  bool get _pastSlop => pendingDelta!.distance > FilesSlopDragRecognizer.slop;

  @override
  void checkForResolutionAfterMove() {
    if (!_pastSlop) {
      return;
    }
    final starter = _starter;
    if (starter == null) {
      resolve(GestureDisposition.accepted);
      return;
    }
    _starter = null;
    starter(initialPosition);
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    // Clicks are a Listener's, not a recognizer's, so the drag is alone in
    // the arena and wins as soon as the button goes down. Starting then
    // showed the drag picture on every click; it waits for real movement.
    if (_pastSlop) {
      starter(initialPosition);
    } else {
      _starter = starter;
    }
  }

  @override
  void dispose() {
    _starter = null;
    super.dispose();
  }
}

/// [child] dragged as [items] in a system drag ([filesSystemDrag]), shown
/// as [feedback] under the pointer.
class FilesSystemDragSource extends StatefulWidget {
  const FilesSystemDragSource({
    super.key,
    required this.controller,
    required this.items,
    required this.feedback,
    required this.child,
  });

  final FilesController controller;

  /// What is dragged, asked for when the drag starts.
  final List<FilesItem> Function() items;
  final Widget feedback;
  final Widget child;

  @override
  State<FilesSystemDragSource> createState() => _FilesSystemDragSourceState();
}

class _FilesSystemDragSourceState extends State<FilesSystemDragSource> {
  final _snapshotter = GlobalKey<WidgetSnapshotterState>();
  static final _feedbackKey = Object();

  /// Where the picture sits from the pointer, as in the window's own drag.
  static const _pictureOffset = Offset(-24, -24);

  Drag? _start(Offset position, int? pointer) {
    final drag = _SystemDrag();
    unawaited(_begin(position, pointer, drag));
    return drag;
  }

  Future<void> _begin(Offset position, int? pointer, _SystemDrag drag) async {
    raw.DragContext? dragContext;
    raw.DragSession? session;
    var started = false;
    try {
      dragContext = await raw.DragContext.instance();
      session = dragContext.newSession(pointer: pointer);
      final items = widget.items();
      final dragItems = [
        for (final item in items) await filesDragItem(widget.controller, item),
      ];
      final picture = await _snapshotter.currentState?.getSnapshot(
        position,
        _feedbackKey,
        () => widget.feedback,
      );
      if (picture == null || drag.ended || !mounted || dragItems.isEmpty) {
        picture?.snapshot.dispose();
        return;
      }
      final rawItems = <raw.DragItem>[];
      for (final (index, item) in dragItems.indexed) {
        final provider = await item.asDataProvider();
        final handle = await item.registerWithDataProvider(provider);
        rawItems.add(
          raw.DragItem(
            dataProvider: handle,
            // One picture; the system counts the items.
            image: index == 0
                ? TargetedWidgetSnapshot(
                    picture.snapshot,
                    (position + _pictureOffset) & picture.rect.size,
                  )
                : _blankPicture(position),
            liftImage: null,
            localData: item.localData,
          ),
        );
      }
      final configuration = raw.DragConfiguration(
        items: rawItems,
        allowedOperations: const [DropOperation.copy],
      );
      session.dragCompleted.addListener(configuration.disposeImages);
      if (!mounted) {
        configuration.disposeImages();
        return;
      }
      started = true;
      await dragContext.startDrag(
        buildContext: context,
        session: session,
        configuration: configuration,
        position: position,
      );
      _hideHoverOnceDragging(session, pointer);
    } catch (error) {
      FilesLog.write('drag: could not start (${error.runtimeType})');
    } finally {
      if (!started && session != null) {
        dragContext!.cancelSession(session);
      }
    }
  }

  /// The system has the pointer while dragging: what it was over in the
  /// window would otherwise stay highlighted.
  static void _hideHoverOnceDragging(raw.DragSession session, int? pointer) {
    if (pointer == null) {
      return;
    }
    Future.delayed(const Duration(milliseconds: 50), () {
      if (session.dragging.value) {
        RendererBinding.instance.mouseTracker.updateWithEvent(
          PointerRemovedEvent(pointer: pointer, kind: PointerDeviceKind.mouse),
          HitTestResult(),
        );
      }
    });
  }

  static TargetedWidgetSnapshot _blankPicture(Offset at) {
    final recorder = ui.PictureRecorder();
    Canvas(recorder);
    final image = recorder.endRecording().toImageSync(1, 1);
    return TargetedWidgetSnapshot(
      WidgetSnapshot.image(image),
      at & const Size(1, 1),
    );
  }

  @override
  Widget build(BuildContext context) {
    return WidgetSnapshotter(
      key: _snapshotter,
      child: RawGestureDetector(
        gestures: {
          FilesSlopDragRecognizer:
              GestureRecognizerFactoryWithHandlers<FilesSlopDragRecognizer>(
                FilesSlopDragRecognizer.new,
                (recognizer) =>
                    recognizer.onStart = (position) =>
                        _start(position, recognizer.pointer),
              ),
        },
        child: widget.child,
      ),
    );
  }
}

class _SystemDrag implements Drag {
  bool ended = false;

  @override
  void update(DragUpdateDetails details) {}

  @override
  void end(DragEndDetails details) => ended = true;

  @override
  void cancel() => ended = true;
}

/// Any kind of file, named by the drag item.
const _anyFile = SimpleFileFormat(
  uniformTypeIdentifiers: ['public.data'],
  mimeTypes: ['application/octet-stream'],
);

const _localDataKey = 'whisperFiles';

/// [item] for a system drag: what the file manager reads back when it is
/// dropped in the window, and the file itself for other apps. Another
/// device's folders stay in the window: other apps only take a file that
/// is still to be fetched.
Future<DragItem> filesDragItem(
  FilesController controller,
  FilesItem item,
) async {
  final dragItem = DragItem(
    suggestedName: item.name,
    localData: <String, Object?>{
      _localDataKey: 1,
      'device': item.location.deviceId,
      'root': item.location.root,
      'folder': item.location.path,
      'name': item.name,
      'dir': item.isDir,
    },
  );
  if (item.location.deviceId == FilesDevice.localId) {
    final path = await controller.localPath(item);
    dragItem.add(Formats.fileUri(Uri.file(path)));
  } else if (!item.isDir) {
    dragItem.addVirtualFile(
      format: _anyFile,
      storageSuggestion: VirtualFileStorage.temporaryFile,
      provider: (sinkProvider, progress) =>
          unawaited(_handOver(controller, item, sinkProvider, progress)),
    );
  }
  return dragItem;
}

/// The file manager's own items in a system drag; null for anything else.
List<FilesItem>? filesItemsOf(DropSession session) {
  final items = <FilesItem>[];
  for (final dropped in session.items) {
    final item = filesItemFromLocalData(dropped.localData);
    if (item == null) {
      return null;
    }
    items.add(item);
  }
  return items.isEmpty ? null : items;
}

/// The item [filesDragItem] put in a drag, read back.
FilesItem? filesItemFromLocalData(Object? data) {
  if (data is! Map || data[_localDataKey] != 1) {
    return null;
  }
  return FilesItem(
    FilesLocation(
      data['device'] as String,
      data['root'] as String,
      data['folder'] as String,
    ),
    data['name'] as String,
    isDir: data['dir'] == true,
  );
}

/// The share of the progress the fetch has; handing the file over is the
/// rest.
const _fetchShare = 0.9;

/// Another device's file dropped in another app: fetched here, then
/// written into what the app gave for it.
Future<void> _handOver(
  FilesController controller,
  FilesItem item,
  VirtualFileEventSinkProvider sinkProvider,
  WriteProgress progress,
) async {
  var canceled = false;
  final fetch = controller.fetchOut(
    item,
    onProgress: (fraction) {
      if (!canceled) {
        progress.updateProgress(fraction * _fetchShare);
      }
    },
  );
  progress.onCancel.addListener(() {
    canceled = true;
    fetch.cancel();
  });
  EventSink<Object?>? sink;
  try {
    final file = File(await fetch.path);
    final size = await file.length();
    final out = sink = sinkProvider(fileSize: size);
    final reader = await file.open();
    try {
      var done = 0;
      while (!canceled) {
        // A piece at a time: the writing happens on this isolate.
        final chunk = await reader.read(1 << 20);
        if (chunk.isEmpty) {
          break;
        }
        out.add(chunk);
        done += chunk.length;
        if (size > 0) {
          progress.updateProgress(
            _fetchShare + (1 - _fetchShare) * done / size,
          );
        }
      }
    } finally {
      await reader.close();
    }
    if (!canceled) {
      out.close();
      FilesLog.write('drag out: handed over');
    }
  } catch (error) {
    if (!canceled) {
      FilesLog.write('drag out: not handed over (${error.runtimeType})');
      (sink ?? sinkProvider(fileSize: 0)).addError(error);
    }
  } finally {
    await fetch.dispose();
  }
}

/// Where items can be dropped: a folder, the folder on screen, a place in
/// the sidebar. Takes the file manager's own drags, of either kind, and
/// with [onPaths] files dragged in from other apps.
class FilesDropTarget extends StatefulWidget {
  const FilesDropTarget({
    super.key,
    required this.controller,
    required this.target,
    required this.onItems,
    this.onPaths,
    this.hitTestBehavior = HitTestBehavior.deferToChild,
    required this.builder,
  });

  final FilesController controller;
  final FilesLocation? target;
  final void Function(List<FilesItem> items, FilesLocation target) onItems;
  final void Function(List<String> paths, FilesLocation target)? onPaths;
  final HitTestBehavior hitTestBehavior;
  final Widget Function(BuildContext context, bool dropping) builder;

  @override
  State<FilesDropTarget> createState() => _FilesDropTargetState();
}

class _FilesDropTargetState extends State<FilesDropTarget> {
  /// A system drag is over it, and would be taken.
  bool _systemOver = false;

  void _setSystemOver(bool over) {
    if (mounted && _systemOver != over) {
      setState(() => _systemOver = over);
    }
  }

  bool _takes(List<FilesItem> items, FilesLocation? target) =>
      target != null && widget.controller.copyProblem(items, target) == null;

  DropOperation _over(DropOverEvent event) {
    final target = widget.target;
    final items = filesItemsOf(event.session);
    final takes = items != null
        ? _takes(items, target)
        : target != null &&
              widget.onPaths != null &&
              event.session.allowedOperations.contains(DropOperation.copy);
    _setSystemOver(takes);
    return takes ? DropOperation.copy : DropOperation.none;
  }

  Future<void> _drop(PerformDropEvent event) async {
    final target = widget.target;
    if (target == null) {
      return;
    }
    final items = filesItemsOf(event.session);
    if (items != null) {
      widget.onItems(items, target);
      return;
    }
    final onPaths = widget.onPaths;
    if (onPaths == null) {
      return;
    }
    final paths = <String>[];
    for (final item in event.session.items) {
      final path = await _droppedPath(item);
      if (path != null) {
        paths.add(path);
      }
    }
    if (paths.isNotEmpty) {
      onPaths(paths, target);
    }
  }

  static Future<String?> _droppedPath(DropItem item) async {
    final reader = item.dataReader;
    if (reader == null) {
      return null;
    }
    final completer = Completer<Uri?>();
    final progress = reader.getValue<Uri>(
      Formats.fileUri,
      (value) => completer.isCompleted ? null : completer.complete(value),
      onError: (_) => completer.isCompleted ? null : completer.complete(null),
    );
    if (progress == null) {
      return null;
    }
    final uri = await completer.future;
    return uri?.isScheme('file') == true ? uri!.toFilePath() : null;
  }

  @override
  Widget build(BuildContext context) {
    final Widget target = DragTarget<FilesDragData>(
      onWillAcceptWithDetails: (details) =>
          _takes(details.data.items, widget.target),
      onAcceptWithDetails: (details) =>
          widget.onItems(details.data.items, widget.target!),
      builder: (context, candidates, _) =>
          widget.builder(context, candidates.isNotEmpty || _systemOver),
    );
    if (!filesSystemDrag && widget.onPaths == null) {
      return target;
    }
    return DropRegion(
      formats: widget.onPaths == null ? const [] : [Formats.fileUri],
      hitTestBehavior: widget.hitTestBehavior,
      onDropOver: _over,
      onDropLeave: (_) => _setSystemOver(false),
      onDropEnded: (_) => _setSystemOver(false),
      onPerformDrop: _drop,
      child: target,
    );
  }
}
