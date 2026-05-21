import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/helper/android_quick_share.dart';

class FakeQuickSharePlatform implements AndroidQuickSharePlatform {
  FakeQuickSharePlatform({
    this.pendingUris = const <String>[],
    this.stagedPaths = const <String>[],
  });

  List<String> pendingUris;
  List<String> stagedPaths;
  List<String> stagedInput = const <String>[];
  Future<void> Function()? handler;

  @override
  void setShareIntentHandler(Future<void> Function() handler) {
    this.handler = handler;
  }

  @override
  Future<List<String>> consumePendingShareUris() async => pendingUris;

  @override
  Future<List<String>> stageSharedUris(List<String> uriStrings) async {
    stagedInput = uriStrings;
    return stagedPaths;
  }
}

void main() {
  test('loads pending Android share uris and stages file paths', () async {
    final platform = FakeQuickSharePlatform(
      pendingUris: const ['content://one', 'content://two'],
      stagedPaths: const ['/cache/one.jpg', '/cache/two.jpg'],
    );
    final share = AndroidQuickShare(platform: platform);

    await share.loadPendingShare();

    expect(platform.stagedInput, ['content://one', 'content://two']);
    expect(share.hasPendingShare, isTrue);
    expect(share.pendingFilePaths, ['/cache/one.jpg', '/cache/two.jpg']);
  });

  test('native share intent callback reloads pending share state', () async {
    final platform = FakeQuickSharePlatform(
      pendingUris: const ['content://warm'],
      stagedPaths: const ['/cache/warm.png'],
    );
    final share = AndroidQuickShare(platform: platform);

    await platform.handler!();

    expect(share.hasPendingShare, isTrue);
    expect(share.pendingFilePaths, ['/cache/warm.png']);
  });

  test('keeps no pending share when there are no stream uris', () async {
    final share = AndroidQuickShare(platform: FakeQuickSharePlatform());

    await share.loadPendingShare();

    expect(share.hasPendingShare, isFalse);
    expect(share.pendingFilePaths, isEmpty);
  });

  test('filters quick share targets to connected peer ids', () {
    final share = AndroidQuickShare(platform: FakeQuickSharePlatform());

    expect(share.isConnectedTarget('peer-a', {'peer-a', 'peer-b'}), isTrue);
    expect(share.isConnectedTarget('peer-c', {'peer-a', 'peer-b'}), isFalse);
  });

  test('clear removes staged pending file paths', () async {
    final share = AndroidQuickShare(
      platform: FakeQuickSharePlatform(
        pendingUris: const ['content://one'],
        stagedPaths: const ['/cache/one.jpg'],
      ),
    );
    await share.loadPendingShare();

    share.clear();

    expect(share.hasPendingShare, isFalse);
    expect(share.pendingFilePaths, isEmpty);
  });
}
