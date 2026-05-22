import 'dart:typed_data';

import 'package:flutter/services.dart';

class AndroidDocumentFile {
  const AndroidDocumentFile({
    required this.uri,
    required this.name,
    required this.size,
    required this.mimeType,
    required this.lastModified,
  });

  final String uri;
  final String name;
  final int size;
  final String mimeType;
  final int lastModified;

  factory AndroidDocumentFile.fromMap(Map<Object?, Object?> map) {
    return AndroidDocumentFile(
      uri: map['uri'] as String? ?? '',
      name: map['name'] as String? ?? 'document',
      size: (map['size'] as num?)?.toInt() ?? 0,
      mimeType: map['mimeType'] as String? ?? '',
      lastModified: (map['lastModified'] as num?)?.toInt() ?? 0,
    );
  }
}

abstract class AndroidDocumentPickerPlatform {
  Future<List<AndroidDocumentFile>> pickFiles({bool allowMultiple = true});

  Future<Uint8List> readBytes({
    required String uri,
    required int offset,
    required int length,
  });

  Future<AndroidDocumentFile?> metadata(String uri);
}

class AndroidDocumentPicker implements AndroidDocumentPickerPlatform {
  AndroidDocumentPicker({
    MethodChannel channel = const MethodChannel(
      'com.vireen.whisper/android_document_picker',
    ),
  }) : _channel = channel;

  static AndroidDocumentPickerPlatform shared = AndroidDocumentPicker();

  final MethodChannel _channel;

  @override
  Future<List<AndroidDocumentFile>> pickFiles({
    bool allowMultiple = true,
  }) async {
    final result = await _channel.invokeListMethod<Object?>(
      'pickFiles',
      <String, Object?>{'allowMultiple': allowMultiple},
    );
    if (result == null) {
      return const <AndroidDocumentFile>[];
    }
    return result
        .whereType<Map<Object?, Object?>>()
        .map(AndroidDocumentFile.fromMap)
        .where((item) => item.uri.isNotEmpty)
        .toList(growable: false);
  }

  @override
  Future<Uint8List> readBytes({
    required String uri,
    required int offset,
    required int length,
  }) async {
    final result = await _channel.invokeMethod<Uint8List>(
      'readBytes',
      <String, Object?>{
        'uri': uri,
        'offset': offset,
        'length': length,
      },
    );
    return result ?? Uint8List(0);
  }

  @override
  Future<AndroidDocumentFile?> metadata(String uri) async {
    final result = await _channel.invokeMapMethod<Object?, Object?>(
      'metadata',
      <String, Object?>{'uri': uri},
    );
    if (result == null) {
      return null;
    }
    return AndroidDocumentFile.fromMap(result);
  }
}
