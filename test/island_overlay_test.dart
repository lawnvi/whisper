import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/widget/island/island_overlay_setting.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  const kotlin = 'android/app/src/main/kotlin/com/vireen/whisper';

  test('files sent in a conversation are not on the island in the app', () {
    expect(
      File('lib/widget/island/sources/transfer_source.dart').existsSync(),
      isFalse,
    );
    expect(
      _read('lib/widget/island/island_sources.dart'),
      isNot(contains('Transfer')),
    );
  });

  test('in the background the transfer notification feeds the island '
      'drawn over other apps', () {
    final plugin = _read('$kotlin/TransferNotificationPlugin.kt');
    expect(plugin, contains('IslandOverlay.progress('));
    expect(plugin, contains('IslandOverlay.waiting('));
    expect(plugin, contains('IslandOverlay.finish('));
    expect(plugin, contains('IslandOverlay.clear()'));
    expect(
      _read('lib/helper/transfer_notifications.dart'),
      contains("'direction': _direction()"),
    );

    final overlay = _read('$kotlin/IslandOverlay.kt');
    // Only while no activity of the app is on screen.
    expect(overlay, contains('started > 0'));
    // Phones that show live updates as their own island keep to that.
    expect(
      overlay,
      contains('UnifiedForegroundNotification.supportsLiveUpdates'),
    );
    // Under the status bar, not over its clock and icons; just as big as
    // the pill or the card, so other touches go to the app below.
    expect(overlay, contains('statusBar + dp(6f)'));
    expect(overlay, contains('FLAG_NOT_TOUCH_MODAL'));
    expect(overlay, isNot(contains('MATCH_PARENT')));
    // A tap opens the card; its buttons stop the round or open Whisper.
    expect(overlay, contains('expand(stay = featured?.urgent == true)'));
    expect(
      overlay,
      contains('Button(stopLabel, Role.NEUTRAL) { onStop?.invoke() }'),
    );
    expect(overlay, contains('IslandOverlay.open(context)'));
    // Springs, as Apple's island moves.
    expect(overlay, contains('private class Spring('));
    // Each update carries on where the last one is, at an even pace.
    expect(overlay, contains('LinearInterpolator(), gap'));
    expect(overlay, contains('Settings.canDrawOverlays'));
    expect(
      _read('$kotlin/MainActivity.kt'),
      contains('IslandOverlay.watch(application)'),
    );
    expect(
      _read('android/app/src/main/AndroidManifest.xml'),
      contains('android.permission.SYSTEM_ALERT_WINDOW'),
    );
  });

  test('the system island gets a percent, an arrow and both ends', () {
    final notification = _read('$kotlin/UnifiedForegroundNotification.kt');
    expect(notification, contains('setShortCriticalText("\$progress%")'));
    expect(
      notification,
      contains('setSmallIcon(transferIcon(state.direction))'),
    );
    expect(notification, contains('setProgressStartIcon'));
    // Thousandths, so the bar does not move a percent at a time.
    expect(notification, contains('Segment(PERMILLE).setColor(TRANSFER_BLUE)'));
    expect(notification, contains('.setProgress(state.permille)'));
    expect(
      _read('$kotlin/TransferNotificationPlugin.kt'),
      contains('EXTRA_PERMILLE, permille'),
    );
    expect(
      _read('lib/helper/transfer_notifications.dart'),
      contains("'permille': command.permille"),
    );
    // Nothing on the right of the opened card: the icon is on the left.
    expect(notification, isNot(contains('setLargeIcon')));
    expect(
      _read('$kotlin/NotificationArt.kt'),
      isNot(contains('fun progress')),
    );
    for (final icon in [
      'ic_stat_send',
      'ic_stat_receive',
      'ic_stat_transfer',
      'ic_stat_flow',
      'ic_device_phone',
      'ic_device_computer',
    ]) {
      expect(
        File('android/app/src/main/res/drawable/$icon.xml').existsSync(),
        isTrue,
        reason: icon,
      );
    }
  });

  test('what needs the user in the background is on the island too', () {
    final connect = _read('$kotlin/ConnectionRequestNotificationPlugin.kt');
    expect(connect, contains('IslandOverlay.put('));
    expect(connect, contains('IslandOverlay.Role.DECLINE'));
    expect(connect, contains('IslandOverlay.fire(context, answerIntent)'));
    expect(connect, contains('setShortCriticalText(code)'));
    // Seen on the island: no banner and sound on top of it.
    expect(connect, contains('builder.setSilent(true)'));
    final streamed = _read('$kotlin/WindowStreamProvider.kt');
    // Flow is the stack of cards the app shows for it.
    expect(streamed, contains('IslandOverlay.Glyph.FLOW'));
    expect(streamed, contains('setSmallIcon(R.drawable.ic_stat_flow)'));
    final asks = _read('$kotlin/IslandPlugin.kt');
    expect(asks, contains('setRequestPromotedOngoing(true)'));
    expect(
      asks,
      contains('IslandOverlay.Glyph.FLOW -> R.drawable.ic_stat_flow'),
    );
    expect(
      asks.indexOf('builder.setLargeIcon('),
      greaterThan(
        asks.indexOf('} else {', asks.indexOf('setRequestPromotedOngoing')),
      ),
    );
    expect(asks, contains('IslandActionReceiver'));
    expect(
      _read('android/app/src/main/AndroidManifest.xml'),
      contains('.IslandActionReceiver'),
    );
    expect(
      _read('lib/page/remote_files/file_browse_prompt.dart'),
      contains('IslandAsks.shared.ask('),
    );
    expect(
      _read('lib/page/window_stream/flow_offer_banner.dart'),
      contains('asks.ask('),
    );
    expect(
      _read('lib/helper/connection_request_notifications.dart'),
      contains("'code': formattedCode"),
    );
  });

  test('settings lead to the system page that allows it', () {
    final settings = _read('lib/page/settings.dart');
    expect(settings, contains('IslandOverlaySetting('));
    expect(
      settings,
      contains('AndroidPrivacyPermission.requestIslandOverlay()'),
    );
    final permissions = _read('$kotlin/AndroidPrivacyPermissionPlugin.kt');
    expect(permissions, contains('Settings.ACTION_MANAGE_OVERLAY_PERMISSION'));
  });

  testWidgets('the settings row shows only where needed, and catches up '
      'on return', (tester) async {
    var state = (needed: false, allowed: false);
    Widget app() => MaterialApp(
      home: IslandOverlaySetting(
        read: () async => state,
        builder: (context, allowed) => Text(allowed ? 'on' : 'off'),
      ),
    );

    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.text('off'), findsNothing);
    expect(find.text('on'), findsNothing);

    state = (needed: true, allowed: false);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await tester.pump();
    expect(find.text('off'), findsOneWidget);

    // Back from the system page with the permission given.
    state = (needed: true, allowed: true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(find.text('on'), findsOneWidget);
  });
}
