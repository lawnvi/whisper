import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const kotlinRoot = 'android/app/src/main/kotlin/com/vireen/whisper';

  String section(String source, String start, String end) =>
      source.substring(source.indexOf(start), source.indexOf(end));

  test('a shared gallery item is sent from the media store, not copied', () {
    final plugin = File(
      '$kotlinRoot/AndroidSystemSharePlugin.kt',
    ).readAsStringSync();
    final stage = section(
      plugin,
      'private fun stageItem(',
      'private fun sourceMetadata(',
    );

    final resolve = stage.indexOf('SharedMediaStoreSource.resolve(');
    expect(resolve, greaterThanOrEqualTo(0));
    expect(resolve, lessThan(stage.indexOf('openInputStream(sourceUri)')));
    expect(stage, contains('.put("uri", stored.uri.toString())'));
    expect(stage, contains('.put("size", stored.size)'));
  });

  test('only a lasting, identical media store entry replaces the copy', () {
    final resolver = File(
      '$kotlinRoot/SharedMediaStoreSource.kt',
    ).readAsStringSync();

    expect(resolver, contains('Environment.isExternalStorageManager()'));
    expect(resolver, contains('Manifest.permission.READ_EXTERNAL_STORAGE'));
    expect(resolver, contains('setOf("picker", "picker_get_content")'));
    expect(resolver, contains('expectedSize != null && expectedSize != size'));
    expect(resolver, contains('cursor.count != 1'));
  });

  test('a completed share keeps only the copies it must release', () {
    final plugin = File(
      '$kotlinRoot/AndroidSystemSharePlugin.kt',
    ).readAsStringSync();
    final complete = section(
      plugin,
      'private fun completePendingEvent(',
      'private fun loadEvents(',
    );

    expect(complete, contains('stagedItems(event.optJSONArray("items")'));
  });

  test('opening a media store entry falls back to an ungranted view', () {
    final picker = File(
      '$kotlinRoot/AndroidDocumentPickerPlugin.kt',
    ).readAsStringSync();
    final open = section(
      picker,
      'private fun openDocument(',
      'private fun readDocumentRange(',
    );

    expect(open, contains('catch (_: SecurityException)'));
    expect(
      open,
      contains('intent.removeFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)'),
    );
  });
}
