import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show HapticFeedback, MethodCall, MethodChannel, PlatformException;
import 'package:flutter/widgets.dart';
import 'package:super_clipboard/super_clipboard.dart'
    show
        DataWriterItem,
        SimpleFileFormat,
        SystemClipboard,
        VirtualFileEventSinkProvider,
        VirtualFileStorage,
        WriteProgress;
import 'package:super_clipboard/super_clipboard_internal.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:super_native_extensions/raw_drag_drop.dart' as raw;

import '../../remote_files/files_log.dart';
import '../../remote_files/fs_copies.dart' show FilesOutside;
import '../../remote_files/fs_placement.dart' show TransferPlacements;
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

/// Explorer pastes a file that is still to be fetched, asking for it once
/// pasted as it does for a drop. Finder only pastes files already on disk
/// (it takes a promised file from a drag, never from the clipboard), and so
/// do Linux file managers: there another device's copied files are pasted
/// in the file manager here, or dragged out ([filesDragsOut]).
bool get filesVirtualClipboard =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// Whether [item], another device's, goes to the system file manager by a
/// drag: a file where drags leave the window ([filesSystemDrag]), a folder
/// to Finder only ([FilesFolderPromises]).
bool filesDragsOut(FilesItem item) =>
    filesSystemDrag &&
    (!item.isDir || defaultTargetPlatform == TargetPlatform.macOS);

/// Puts another device's files on the system clipboard, each fetched when
/// an app pastes it. False if the clipboard did not take them.
Future<bool> writeFetchedToClipboard(
  FilesController controller,
  List<FilesItem> items,
) async {
  final clipboard = SystemClipboard.instance;
  if (clipboard == null) {
    return false;
  }
  try {
    await clipboard.write([
      for (final item in items)
        DataWriterItem(suggestedName: item.name)..addVirtualFile(
          format: _anyFile,
          storageSuggestion: VirtualFileStorage.temporaryFile,
          provider: (sinkProvider, progress) => unawaited(
            _handOver(controller, item, sinkProvider, progress, as: 'paste'),
          ),
        ),
    ]);
    return true;
  } catch (error) {
    FilesLog.write('clipboard: not written (${error.runtimeType})');
    return false;
  }
}

/// A finger or a pen, not a mouse: on a tablet showing the desktop layout,
/// it scrolls the list and taps; holding an item picks it up.
bool filesTouchPointer(PointerDeviceKind kind) =>
    kind == PointerDeviceKind.touch ||
    kind == PointerDeviceKind.stylus ||
    kind == PointerDeviceKind.invertedStylus;

/// Starts a drag once the pointer has moved a little, however long the
/// button was held first. A finger has to hold the item first (as in the
/// Files app): moved at once, it scrolls the list instead. With
/// [liftOnHold] off, the hold only readies it: moving on drags, letting go
/// is left to the item (its menu; a menu pushed while the finger is down
/// would cancel the finger, and with it the drag).
class FilesSlopDragRecognizer extends MultiDragGestureRecognizer {
  FilesSlopDragRecognizer({this.liftOnHold = true}) : super(debugOwner: null);

  /// How far the pointer moves before it is a drag.
  static const double slop = 6;

  final bool liftOnHold;

  /// The pointer of the latest drag.
  int? pointer;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    pointer = event.pointer;
    super.addAllowedPointer(event);
  }

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) =>
      filesTouchPointer(event.kind)
      ? _HoldPointerState(
          event.position,
          event.kind,
          gestureSettings,
          liftOnHold: liftOnHold,
        )
      : _SlopPointerState(event.position, event.kind, gestureSettings);

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

/// A finger: moving at once gives the pointer to the list (it scrolls);
/// held still for a long press it is picked up, at once or (without
/// [liftOnHold]) once it moves on.
class _HoldPointerState extends MultiDragPointerState {
  _HoldPointerState(
    super.initialPosition,
    super.kind,
    super.deviceGestureSettings, {
    required this.liftOnHold,
  }) {
    _timer = Timer(kLongPressTimeout, _held);
  }

  final bool liftOnHold;

  Timer? _timer;
  bool _isHeld = false;
  bool _lifted = false;
  GestureMultiDragStartCallback? _starter;

  void _held() {
    _timer = null;
    _isHeld = true;
    unawaited(HapticFeedback.selectionClick());
    if (liftOnHold) {
      _lift();
    }
  }

  void _lift() {
    if (_lifted) {
      return;
    }
    _lifted = true;
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
    if (_lifted) {
      starter(initialPosition);
    } else {
      _starter = starter;
    }
  }

  @override
  void checkForResolutionAfterMove() {
    final moved =
        pendingDelta!.distance > computeHitSlop(kind, gestureSettings);
    if (!_isHeld) {
      if (moved) {
        _timer?.cancel();
        _timer = null;
        _starter = null;
        resolve(GestureDisposition.rejected);
      }
      return;
    }
    if (moved && !_lifted) {
      _lift();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
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
        () => filesDragPicture(widget.feedback),
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

/// [feedback] as the system drag's picture, at its own size: under the
/// dragged row's constraints it was stretched into a long strip as wide as
/// the row.
Widget filesDragPicture(Widget feedback) => SnapshotSettings(
  constraintsTransform: (_) => const BoxConstraints(),
  child: feedback,
);

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

/// A folder, promised to Finder: the runner fulfils it ([FilesFolderPromises]).
const _folder = SimpleFileFormat(uniformTypeIdentifiers: ['public.folder']);

/// [item] for a system drag: what the file manager reads back when it is
/// dropped in the window, and the file itself for other apps. Another
/// device's folders go to Finder only ([FilesFolderPromises]); Explorer
/// takes a file still to be fetched, not a folder.
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
  } else if (defaultTargetPlatform == TargetPlatform.macOS) {
    FilesFolderPromises.offer(controller, item);
    dragItem.addVirtualFile(
      format: _folder,
      storageSuggestion: VirtualFileStorage.temporaryFile,
      // The runner writes folders itself; here only if it did not.
      provider: (sinkProvider, progress) {
        FilesLog.write('drag out: folder promise reached the plugin');
        sinkProvider(
          fileSize: 0,
        ).addError(const FileSystemException('a folder, not a file'));
      },
    );
  }
  return dragItem;
}

/// Another device's folders dragged out to Finder. The runner
/// (`FolderPromises` in MainFlutterWindow.swift) makes the folder where
/// Finder asks and has it filled here: the folder comes over as one copy
/// (listed with the others) and moves in once it is all here, while Finder
/// shows the progress on it.
abstract final class FilesFolderPromises {
  static const _channel = MethodChannel('com.vireen.whisper/folder_promises');

  /// The folders in drags so far, by name (what Finder asks for).
  static final _offered =
      <String, ({FilesController controller, FilesItem item})>{};

  /// What is being written, by the runner's id.
  static final _writing = <String, FilesFetchOut>{};

  static bool _listening = false;

  static void offer(FilesController controller, FilesItem item) {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler(_handle);
    }
    _offered[item.name] = (controller: controller, item: item);
  }

  static Future<Object?> _handle(MethodCall call) async {
    final arguments = call.arguments;
    if (arguments is! Map) {
      return null;
    }
    final id = arguments['id'];
    switch (call.method) {
      case 'write':
        final name = arguments['name'];
        final path = arguments['path'];
        final offered = _offered[name];
        if (id is! String || path is! String || offered == null) {
          throw PlatformException(code: 'unknown', message: '$name');
        }
        await _write(id, offered.controller, offered.item, path);
      case 'cancel':
        _writing[id]?.cancel();
    }
    return null;
  }

  static Future<void> _write(
    String id,
    FilesController controller,
    FilesItem item,
    String destination,
  ) async {
    try {
      await fill(
        controller,
        item,
        destination,
        started: (fetch) => _writing[id] = fetch,
        onProgress: (fraction) => unawaited(
          _channel
              .invokeMethod<void>('progress', {'id': id, 'fraction': fraction})
              .catchError((Object _) {}),
        ),
      );
    } catch (error) {
      throw PlatformException(code: 'failed', message: '$error');
    } finally {
      _writing.remove(id);
    }
  }

  /// Fetches [item], another device's folder, into [destination] (an
  /// empty folder): one copy, listed with the others. [started] gets the
  /// fetch, to cancel it.
  static Future<void> fill(
    FilesController controller,
    FilesItem item,
    String destination, {
    void Function(FilesFetchOut fetch)? started,
    void Function(double fraction)? onProgress,
  }) async {
    final fetch = controller.fetchOut(
      item,
      shownAs: FilesOutside.fileManager,
      onProgress: onProgress,
    );
    started?.call(fetch);
    try {
      await moveFolderInto(await fetch.path, destination);
      FilesLog.write('drag out: folder handed over');
    } catch (error) {
      FilesLog.write('drag out: folder not handed over (${error.runtimeType})');
      rethrow;
    } finally {
      await fetch.dispose();
    }
  }

  /// Puts the folder [from] where [to] is, an empty folder Finder shows:
  /// renamed over it on the same volume, else what is in it moved in.
  @visibleForTesting
  static Future<void> moveFolderInto(String from, String to) async {
    try {
      await Directory(from).rename(to);
      return;
    } on FileSystemException {
      // Another volume, or something put in it meanwhile.
    }
    await for (final entity in Directory(from).list()) {
      await TransferPlacements.moveInto(entity.path, to);
    }
    await Directory(from).delete(recursive: true);
  }
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

/// Another device's file dropped or pasted in another app, written into
/// what that app gave for it as it arrives (see [filesHandOver]). The copy
/// is listed with the others (island, Transfers). [as] names how in the log.
Future<void> _handOver(
  FilesController controller,
  FilesItem item,
  VirtualFileEventSinkProvider sinkProvider,
  WriteProgress progress, {
  String as = 'drag out',
}) async {
  var canceled = false;
  final fetch = controller.fetchOut(item, shownAs: FilesOutside.fileManager);
  progress.onCancel.addListener(() {
    canceled = true;
    fetch.cancel();
  });
  EventSink<Object?>? sink;
  try {
    await filesHandOver(
      fetch,
      open: (size) => sink = sinkProvider(fileSize: size),
      onProgress: progress.updateProgress,
      canceled: () => canceled,
    );
    if (!canceled) {
      sink!.close();
      FilesLog.write('$as: handed over');
    }
  } catch (error) {
    if (!canceled) {
      FilesLog.write('$as: not handed over (${error.runtimeType})');
      (sink ?? sinkProvider(fileSize: 0)).addError(error);
    }
  } finally {
    await fetch.dispose();
  }
}

/// Writes [fetch]'s file into the sink [open] gives, as it arrives: the
/// sink opens as soon as the size is known (Explorer then shows its own copy
/// progress; Finder's file grows) and gets each piece once the transfer
/// committed it, rather than an empty file until the whole of it is here.
/// Throws when the fetch fails or not all of it came.
@visibleForTesting
Future<void> filesHandOver(
  FilesFetchOut fetch, {
  required EventSink<Object?> Function(int size) open,
  void Function(double fraction)? onProgress,
  bool Function()? canceled,
}) async {
  bool stop() => canceled?.call() ?? false;
  // Woken whenever more has arrived (or the fetch settled).
  var wake = Completer<void>();
  void poke() {
    if (!wake.isCompleted) {
      wake.complete();
    }
  }

  fetch.arriving.addListener(poke);
  unawaited(fetch.path.then((_) => poke(), onError: (Object _) => poke()));
  EventSink<Object?>? sink;
  RandomAccessFile? reader;
  String? readingFrom;
  var done = 0;
  var size = -1;

  /// Hands over what of [path] is here up to [end].
  Future<void> pump(String path, int end) async {
    if (readingFrom != path) {
      await reader?.close();
      reader = null;
      reader = await File(path).open();
      readingFrom = path;
    }
    final file = reader!;
    end = math.min(end, await file.length());
    while (done < end && !stop()) {
      await file.setPosition(done);
      final chunk = await file.read(math.min(1 << 20, end - done));
      if (chunk.isEmpty) {
        break;
      }
      sink!.add(chunk);
      done += chunk.length;
      if (size > 0) {
        onProgress?.call(done / size);
      }
    }
  }

  try {
    while (!stop()) {
      final before = done;
      final arrived = fetch.arriving.value;
      if (sink == null && arrived != null) {
        size = arrived.size;
        sink = open(size);
      }
      if (fetch.settled) {
        final path = await fetch.path;
        if (sink == null) {
          size = await File(path).length();
          sink = open(size);
        }
        await pump(path, size);
        break;
      }
      if (arrived != null &&
          arrived.temp.isNotEmpty &&
          arrived.committed > done) {
        try {
          await pump(arrived.temp, arrived.committed);
        } on FileSystemException {
          // Moved to where it lands as it finished: read from there next.
          await reader?.close();
          reader = null;
          readingFrom = null;
          await Future<void>.delayed(const Duration(milliseconds: 50));
          continue;
        }
      }
      // Nothing new handed over (not written yet, or only the finished
      // file's path to come): wait for more rather than spin.
      wake = Completer<void>();
      if (!fetch.settled && done == before) {
        await Future.any([
          wake.future,
          Future<void>.delayed(const Duration(milliseconds: 250)),
        ]);
      }
    }
    if (!stop() && done != size) {
      throw FileSystemException('handed over $done of $size bytes');
    }
  } finally {
    fetch.arriving.removeListener(poke);
    await reader?.close();
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
