import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/widget/island/island_activity.dart';
import 'package:whisper/widget/island/sources/streamed_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('this phone being streamed', () {
    const channel = MethodChannel('island-test/window_stream_phone');
    late List<MethodCall> calls;
    late StreamedIslandSource source;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'state') {
              return {'windows': 0, 'viewer': '', 'stopping': false};
            }
            return null;
          });
      source = StreamedIslandSource(channel: channel, enabled: true);
    });

    tearDown(() {
      source.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('streamed, stopped from the island, then over', () async {
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => c.method), ['state']);
      expect(source.activities, isEmpty);

      source.apply({'windows': 2, 'viewer': 'MacBook', 'stopping': false});
      final live = source.activities.single;
      expect(live.kind, IslandKind.streamed);
      expect(live.status, IslandStatus.live);
      expect(live.urgent, isTrue);
      final presenter = live.presenter as StreamedPresenter;
      expect(presenter.windows, 2);
      expect(presenter.viewer, 'MacBook');

      await presenter.stop();
      expect(calls.last.method, 'stop');
      expect(
        (source.activities.single.presenter as StreamedPresenter).stopping,
        isTrue,
      );

      source.apply({'windows': 0, 'viewer': 'MacBook', 'stopping': false});
      expect(source.activities.single.status, IslandStatus.ended);
      source.retired(live.id);
      expect(source.activities, isEmpty);

      source.apply({'windows': 1, 'viewer': 'PC', 'stopping': false});
      expect(source.activities.single.id, isNot(live.id));
    });
  });
}
