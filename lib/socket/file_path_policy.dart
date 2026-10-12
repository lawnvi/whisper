import 'dart:io';

import 'package:path/path.dart' as p;

export 'transfer_file_name.dart';
export 'verified_file_publisher.dart';

final RegExp _canonicalTransferId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);
Future<String> safeTransferTempPath(Directory root, String transferId) async {
  if (!_canonicalTransferId.hasMatch(transferId)) {
    throw const FormatException('invalid transfer id');
  }
  final canonicalRoot = p.normalize(await root.resolveSymbolicLinks());
  final canonicalTransferDirectory = await _resolveChildDirectoryWithoutCreate(
    canonicalRoot,
    const <String>['.whisper', 'transfers'],
  );
  if (!_isWithinOrEqual(canonicalRoot, canonicalTransferDirectory)) {
    throw FileSystemException(
      'transfer directory escapes download root',
      canonicalTransferDirectory,
    );
  }
  final candidate = p.normalize(
    p.join(canonicalTransferDirectory, '$transferId.part'),
  );
  if (p.dirname(candidate) != canonicalTransferDirectory ||
      !p.isWithin(canonicalRoot, candidate)) {
    throw FileSystemException('transfer path escapes download root', candidate);
  }
  final candidateType = await FileSystemEntity.type(
    candidate,
    followLinks: false,
  );
  if (candidateType != FileSystemEntityType.notFound &&
      candidateType != FileSystemEntityType.file) {
    throw FileSystemException('transfer temp is not a regular file', candidate);
  }
  return candidate;
}

Future<File> revalidateTransferTempFile({
  required Directory root,
  required String transferId,
  required String expectedPath,
}) async {
  final safePath = await safeTransferTempPath(root, transferId);
  if (!p.equals(p.normalize(expectedPath), safePath)) {
    throw FileSystemException(
      'transfer temp path changed outside its download root',
      expectedPath,
    );
  }
  return File(safePath);
}

/// Where an incoming folder is assembled before it is published: a
/// directory of its own beside the `.part` files, on the same volume as the
/// downloads so that publishing is a rename.
Future<String> safeFolderStagingPath(Directory root, String transferId) async {
  if (!_canonicalTransferId.hasMatch(transferId)) {
    throw const FormatException('invalid transfer id');
  }
  final canonicalRoot = p.normalize(await root.resolveSymbolicLinks());
  final canonicalTransferDirectory = await _resolveChildDirectoryWithoutCreate(
    canonicalRoot,
    const <String>['.whisper', 'transfers'],
  );
  if (!_isWithinOrEqual(canonicalRoot, canonicalTransferDirectory)) {
    throw FileSystemException(
      'transfer directory escapes download root',
      canonicalTransferDirectory,
    );
  }
  final candidate = p.normalize(
    p.join(canonicalTransferDirectory, '$transferId.folder'),
  );
  if (p.dirname(candidate) != canonicalTransferDirectory ||
      !p.isWithin(canonicalRoot, candidate)) {
    throw FileSystemException('transfer path escapes download root', candidate);
  }
  final candidateType = await FileSystemEntity.type(
    candidate,
    followLinks: false,
  );
  if (candidateType != FileSystemEntityType.notFound &&
      candidateType != FileSystemEntityType.directory) {
    throw FileSystemException('folder staging is not a directory', candidate);
  }
  return candidate;
}

Future<Directory> revalidateFolderStagingDirectory({
  required Directory root,
  required String transferId,
  required String expectedPath,
}) async {
  final safePath = await safeFolderStagingPath(root, transferId);
  if (!p.equals(p.normalize(expectedPath), safePath)) {
    throw FileSystemException(
      'folder staging path changed outside its download root',
      expectedPath,
    );
  }
  return Directory(safePath);
}

Future<String> _resolveChildDirectoryWithoutCreate(
  String canonicalRoot,
  List<String> segments,
) async {
  var current = canonicalRoot;
  for (final segment in segments) {
    final next = p.normalize(p.join(current, segment));
    final type = await FileSystemEntity.type(next, followLinks: false);
    switch (type) {
      case FileSystemEntityType.notFound:
        current = next;
        break;
      case FileSystemEntityType.directory:
        current = p.normalize(await Directory(next).resolveSymbolicLinks());
        break;
      case FileSystemEntityType.link:
        final resolved = p.normalize(await Link(next).resolveSymbolicLinks());
        if (await FileSystemEntity.type(resolved) !=
            FileSystemEntityType.directory) {
          throw FileSystemException('transfer parent is not a directory', next);
        }
        current = resolved;
        break;
      case FileSystemEntityType.file:
      case FileSystemEntityType.unixDomainSock:
      case FileSystemEntityType.pipe:
        throw FileSystemException('transfer parent is not a directory', next);
    }
    if (!_isWithinOrEqual(canonicalRoot, current)) {
      throw FileSystemException(
        'transfer directory escapes download root',
        current,
      );
    }
  }
  return current;
}

bool _isWithinOrEqual(String parent, String child) =>
    p.equals(parent, child) || p.isWithin(parent, child);
