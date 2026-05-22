import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:whisper/helper/android_document_picker.dart';

class PickedTransferFile {
  const PickedTransferFile({
    required this.name,
    required this.size,
    required this.lastModified,
    this.path,
    this.androidContentUri,
  });

  final String name;
  final int size;
  final int lastModified;
  final String? path;
  final String? androidContentUri;

  bool get isAndroidContentUri =>
      androidContentUri != null && androidContentUri!.isNotEmpty;
}

class WhisperFilePicker {
  const WhisperFilePicker._();

  static Future<List<PickedTransferFile>> pickFiles({
    bool allowMultiple = true,
  }) async {
    if (Platform.isAndroid) {
      final items = await AndroidDocumentPicker.shared.pickFiles(
        allowMultiple: allowMultiple,
      );
      final now = DateTime.now().millisecondsSinceEpoch;
      return items
          .map(
            (item) => PickedTransferFile(
              name: item.name,
              size: item.size,
              lastModified: item.lastModified > 0 ? item.lastModified : now,
              androidContentUri: item.uri,
            ),
          )
          .toList(growable: false);
    }

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: allowMultiple,
    );
    if (result == null) {
      return const <PickedTransferFile>[];
    }

    final items = <PickedTransferFile>[];
    for (final item in result.files) {
      final path = item.path;
      if (path == null || path.isEmpty) {
        continue;
      }
      var lastModified = DateTime.now().millisecondsSinceEpoch;
      try {
        lastModified = (await File(path).lastModified()).millisecondsSinceEpoch;
      } catch (_) {
        // Keep a stable best-effort timestamp when the platform picker does not
        // expose one and the file metadata cannot be read.
      }
      items.add(
        PickedTransferFile(
          name: item.name,
          size: item.size,
          lastModified: lastModified,
          path: path,
        ),
      );
    }
    return items;
  }
}
