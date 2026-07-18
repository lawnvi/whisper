import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android system share accepts text and content streams', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final activity = File(
      'android/app/src/main/kotlin/com/vireen/whisper/MainActivity.kt',
    ).readAsStringSync();
    final plugin = File(
      'android/app/src/main/kotlin/com/vireen/whisper/AndroidSystemSharePlugin.kt',
    ).readAsStringSync();
    final deviceList = File('lib/page/deviceList.dart').readAsStringSync();
    final router = File(
      'lib/state/android_system_share_router.dart',
    ).readAsStringSync();
    final transferEngine = File(
      'lib/socket/file_transfer_engine.dart',
    ).readAsStringSync();
    final zhArb = File('lib/l10n/app_zh.arb').readAsStringSync();

    expect(manifest, contains('android.intent.action.SEND'));
    expect(manifest, contains('android.intent.action.SEND_MULTIPLE'));
    expect(manifest, contains('android:mimeType="*/*"'));
    expect(manifest, contains('android:launchMode="singleTop"'));
    expect(activity, contains('AndroidSystemSharePlugin()'));
    expect(plugin, contains('PluginRegistry.NewIntentListener'));
    expect(plugin, contains('captureShareIntent(binding.activity.intent)'));
    expect(plugin, contains('Intent.EXTRA_TEXT'));
    expect(plugin, contains('Intent.EXTRA_STREAM'));
    expect(plugin, contains('intent.clipData'));
    expect(plugin, contains('OpenableColumns.DISPLAY_NAME'));
    expect(plugin, contains('OpenableColumns.SIZE'));
    expect(plugin, contains('ContentResolver.SCHEME_CONTENT'));
    expect(plugin, contains('consumePendingShares'));
    expect(plugin, contains('MAX_PENDING_EVENTS'));
    expect(plugin, contains('MAX_ITEMS_PER_EVENT'));
    expect(plugin, contains('consumePendingShareFailures'));
    expect(plugin, contains('shareIntentRejected'));
    expect(plugin, contains('FAILURE_QUEUE_FULL'));
    expect(plugin, contains('FAILURE_TOO_MANY_ITEMS'));
    expect(
      plugin,
      contains('loadEvents(pendingOnly = true).size >= MAX_PENDING_EVENTS'),
    );
    expect(plugin, isNot(contains('trimPendingEvents()')));
    expect(plugin, isNot(contains('snapshot.uris.take(MAX_ITEMS_PER_EVENT)')));
    expect(plugin, contains('FileOutputStream(partialFile)'));
    expect(plugin, contains('ByteArray(STREAM_BUFFER_SIZE)'));
    expect(plugin, contains('output.write(buffer, 0, read)'));
    expect(plugin, contains('AtomicFile'));
    expect(plugin, contains('context.filesDir'));
    expect(plugin, contains('updatePendingShareProgress'));
    expect(plugin, contains('targetPublicKeyHash'));
    expect(plugin, contains('completePendingShare'));
    expect(plugin, contains('releaseStagedShareItem'));
    expect(plugin, isNot(contains('readBytes()')));
    expect(plugin, isNot(contains('cacheDir')));
    expect(manifest, contains('androidx.core.content.FileProvider'));
    expect(manifest, contains('android_system_share_paths'));
    expect(deviceList, contains('AndroidSystemShareInbox.shared'));
    expect(
      deviceList,
      contains(
        '_androidSystemShareInbox.addListener(_handleAndroidSystemShareChanged)',
      ),
    );
    expect(deviceList, contains('_androidSystemShareInbox.initialize()'));
    expect(deviceList, contains('_androidSystemShareInbox.removeListener('));
    expect(deviceList, contains('showModalBottomSheet<String>'));
    expect(deviceList, contains('onlineTargets.length == 1'));
    expect(deviceList, contains('locallyTrusted'));
    expect(deviceList, contains('socketManager.sendMessageTo'));
    expect(deviceList, contains('socketManager.sendQuickPickedFileToDurably'));
    expect(deviceList, contains("source: 'android-system-share-file'"));
    expect(
      deviceList,
      contains('jsonEncode(<String>[event.id, item.uri, pinnedHash])'),
    );
    expect(deviceList, contains('sendText: _sendAndroidSystemShareText'));
    expect(deviceList, contains('jsonEncode(<String>[event.id, pinnedHash])'));
    expect(deviceList, contains('androidContentUri: item.uri'));
    expect(deviceList, contains('_retryConnectedAndroidSystemShares()'));
    expect(router, contains('AndroidSystemShareRouteOutcome.failed'));
    expect(router, contains('progress.sentItemUris.contains(item.uri)'));
    expect(router, contains('await _inbox.complete(eventId)'));
    expect(router, contains('_persistProgress(eventId, progress)'));
    expect(
      transferEngine,
      contains('releaseAndroidSystemShareStagedItem(updated.finalPath)'),
    );
    expect(zhArb, contains('"androidSystemShareChooseTrustedDevice"'));
    expect(zhArb, contains('"androidSystemShareFailedRetained"'));
  });
}
