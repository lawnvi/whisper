import 'dart:io';

/// macOS's own NFS client mounting an [NfsServer] on 127.0.0.1: no kernel
/// extension, no administrator, and Finder shows it like any server.
abstract final class MacNfsMount {
  /// Soft, so a call fails instead of hanging when Whisper is gone, and
  /// marked dead (unmounted by the system) ten seconds after that;
  /// `mutejukebox` keeps a slow device's "try again" out of the system's
  /// "server not responding" dialog. `dumbtimer` holds the client to
  /// `timeo`: estimated from quick answers, its timeout shrank to a second
  /// or so, and a busy phone's reads failed (ETIMEDOUT) and got the mount
  /// declared dead, though every call is answered within the server's
  /// patience.
  static List<String> options(int port) => [
    'vers=3',
    'tcp',
    'port=$port',
    'mountport=$port',
    'rdonly',
    'locallocks',
    'soft',
    'intr',
    'timeo=100',
    'dumbtimer',
    'retrans=3',
    'deadtimeout=10',
    'mutejukebox',
    'noquota',
    'rdirplus',
    'rsize=1048576',
    'actimeo=2',
  ];

  static Future<void> mount({
    required int port,
    required String export,
    required String mountPoint,
  }) async {
    await Directory(mountPoint).create(recursive: true);
    final result = await Process.run('/sbin/mount_nfs', [
      '-o',
      options(port).join(','),
      'localhost:$export',
      mountPoint,
    ]);
    if (result.exitCode != 0) {
      throw ProcessException(
        '/sbin/mount_nfs',
        const [],
        '${result.stderr}'.trim(),
        result.exitCode,
      );
    }
  }

  /// Unmounts [mountPoint], by force when something still has it open
  /// (its files are gone with the other device anyway).
  static Future<bool> unmount(String mountPoint) async {
    var result = await Process.run('/sbin/umount', [mountPoint]);
    if (result.exitCode != 0) {
      result = await Process.run('/sbin/umount', ['-f', mountPoint]);
    }
    if (result.exitCode == 0) {
      try {
        await Directory(mountPoint).delete();
      } on FileSystemException {
        // Something else was put there; leave it.
      }
    }
    return result.exitCode == 0;
  }

  /// Mount points under [base] that are mounted from this Mac's own NFS
  /// server: Whisper's, left from a run that did not get to unmount them.
  static Future<List<String>> mountedUnder(String base) async {
    final result = await Process.run('/sbin/mount', const []);
    if (result.exitCode != 0) {
      return const [];
    }
    final prefix = base.endsWith('/') ? base : '$base/';
    final points = <String>[];
    for (final line in '${result.stdout}'.split('\n')) {
      // "localhost:/<token>/<name> on <point> (nfs, ...)"; the name may
      // hold spaces, the point is under [base].
      final at = line.indexOf(' on $prefix');
      final end = line.lastIndexOf(' (nfs');
      if (!line.startsWith('localhost:/') || at < 0 || end < at) {
        continue;
      }
      points.add(line.substring(at + 4, end));
    }
    return points;
  }
}
