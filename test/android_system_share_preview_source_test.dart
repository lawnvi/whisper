import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const kotlinRoot = 'android/app/src/main/kotlin/com/vireen/whisper';

  test(
    'a shared photo or video keeps a preview after its copy is released',
    () {
      final plugin = File(
        '$kotlinRoot/AndroidSystemSharePlugin.kt',
      ).readAsStringSync();
      final release = plugin.substring(
        plugin.indexOf('private fun releaseStagedItem('),
        plugin.indexOf('private fun stagedFileFor('),
      );

      final retain = release.indexOf('AndroidSystemSharePreviews.retain(');
      final delete = release.indexOf(
        'stagedFileFor(item.optString("uri"))?.delete()',
      );
      expect(retain, greaterThanOrEqualTo(0));
      expect(delete, greaterThan(retain));
      expect(release, contains('item.optString("mimeType")'));
    },
  );

  test('thumbnails of a released item fall back to its kept preview', () {
    final picker = File(
      '$kotlinRoot/AndroidDocumentPickerPlugin.kt',
    ).readAsStringSync();
    final previews = File(
      '$kotlinRoot/AndroidSystemSharePreviews.kt',
    ).readAsStringSync();

    expect(
      picker,
      contains(
        '?: AndroidSystemSharePreviews.load(context, uri, width, height)',
      ),
    );
    expect(previews, contains('mimeType.startsWith("image/")'));
    expect(previews, contains('mimeType.startsWith("video/")'));
    expect(previews, contains('AtomicFile(target)'));
    expect(previews, contains('MAX_TOTAL_BYTES'));
    expect(previews, contains('value != "." && value != ".."'));
    expect(previews, contains(r'"${context.packageName}.system_share_files"'));
  });

  test('a video in a plain file provider still gets a frame', () {
    final thumbnails = File(
      '$kotlinRoot/MediaThumbnails.kt',
    ).readAsStringSync();
    final video = thumbnails.substring(
      thumbnails.indexOf('if (mimeType.startsWith("video/")) {'),
    );

    expect(
      video.indexOf('contentResolver.loadThumbnail'),
      lessThan(video.indexOf('retriever.setDataSource(context, uri)')),
    );
    expect(video, contains('} catch (_: Exception) {'));
  });

  test('shared items without an extension get one from their type', () {
    final plugin = File(
      '$kotlinRoot/AndroidSystemSharePlugin.kt',
    ).readAsStringSync();

    expect(plugin, contains('MimeTypeMap.getSingleton()'));
    expect(
      plugin,
      contains(
        'val displayName = withTypeExtension(metadata.displayName, '
        'metadata.mimeType)',
      ),
    );
    expect(
      plugin,
      contains(
        '.put("displayName", displayName.take(MAX_DISPLAY_NAME_LENGTH))',
      ),
    );
  });
}
