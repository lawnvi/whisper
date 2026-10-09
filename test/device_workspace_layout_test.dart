import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/widget/device_workspace_layout.dart';

void main() {
  test('iPad adapts from portrait and narrow split view to landscape', () {
    for (final width in [320.0, 507.0, 768.0, 839.0]) {
      expect(
        usesSplitDeviceWorkspace(width: width, desktop: false, ios: true),
        false,
      );
    }
    for (final width in [840.0, 1024.0, 1366.0]) {
      expect(
        usesSplitDeviceWorkspace(width: width, desktop: false, ios: true),
        true,
      );
    }
  });

  test('desktop keeps its workspace and Android keeps its mobile layout', () {
    expect(
      usesSplitDeviceWorkspace(width: 700, desktop: true, ios: false),
      true,
    );
    expect(
      usesSplitDeviceWorkspace(width: 1024, desktop: false, ios: false),
      false,
    );
  });

  test('a narrow iPad window retains its selected conversation', () {
    expect(
      usesRetainedTabletWorkspace(ios: true, displayShortestSide: 768),
      isTrue,
    );
  });

  test('phones and Android retain their existing route navigation', () {
    expect(
      usesRetainedTabletWorkspace(ios: true, displayShortestSide: 430),
      isFalse,
    );
    expect(
      usesRetainedTabletWorkspace(ios: false, displayShortestSide: 768),
      isFalse,
    );
  });
}
