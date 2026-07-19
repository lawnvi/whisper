import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows snapshots bare quick-send clipboard payloads natively', () {
    final quickSend = File(
      'windows/runner/desktop_quick_send_plugin.cpp',
    ).readAsStringSync();
    final clipboard = File(
      'windows/runner/desktop_clipboard_image_plugin.cpp',
    ).readAsStringSync();
    final clipboardHeader = File(
      'windows/runner/desktop_clipboard_image_plugin.h',
    ).readAsStringSync();

    expect(quickSend, contains('IsBareQuickSendCommand(arguments)'));
    expect(quickSend, contains('DesktopClipboardSnapshotQuickSendArguments()'));
    expect(quickSend, contains('queued_arguments = &*clipboard_arguments'));
    expect(
      quickSend,
      contains('PendingEntry{NewId("windows"), *queued_arguments}'),
    );
    expect(
      clipboardHeader,
      contains('DesktopClipboardSnapshotQuickSendArguments'),
    );

    final fileSnapshot = clipboard.indexOf(
      'ReadClipboardFilePathsFromOpenClipboard()',
      clipboard.indexOf('ReadClipboardQuickSendArguments'),
    );
    final textSnapshot = clipboard.indexOf(
      'ReadClipboardUnicodeTextFromOpenClipboard()',
      clipboard.indexOf('ReadClipboardQuickSendArguments'),
    );
    expect(fileSnapshot, greaterThanOrEqualTo(0));
    expect(textSnapshot, greaterThan(fileSnapshot));
    expect(clipboard, contains('arguments.emplace_back("--quick-send-file")'));
    expect(
      clipboard,
      contains('std::vector<std::string>{"--quick-send-text", *text}'),
    );
  });

  test('Windows persists a visible rejection when snapshot is unavailable', () {
    final source = File(
      'windows/runner/desktop_quick_send_plugin.cpp',
    ).readAsStringSync();

    expect(source, contains('clipboardSnapshotUnavailable'));
    expect(source, contains('kClipboardSnapshotUnavailableReason, 0'));
    expect(
      source,
      contains('AppendString(&output, pending_rejection->reason)'),
    );
    expect(source, contains('pending_rejection->limit'));
    expect(source, contains('flutter::EncodableValue(rejection.reason)'));
    expect(source, contains('flutter::EncodableValue(rejection.limit)'));
    expect(source, contains('if (!PersistState())'));
    expect(source, contains('(version != 1 && version != kStateVersion)'));
  });

  test(
    'Windows rejects legacy bare entries instead of reading a later clipboard',
    () {
      final source = File(
        'windows/runner/desktop_quick_send_plugin.cpp',
      ).readAsStringSync();

      expect(source, contains('IsBareQuickSendCommand(entry.arguments)'));
      expect(source, contains('decoded.erase(retained_end, decoded.end())'));
      expect(source, contains('if (removed_legacy_bare)'));
      expect(
        source,
        contains('Historical bare triggers cannot be snapshotted'),
      );
      expect(
        RegExp(
          r'DesktopClipboardSnapshotQuickSendArguments\(\)',
        ).allMatches(source),
        hasLength(1),
      );
    },
  );

  test('Windows rejects image-only, empty, and inaccessible clipboards', () {
    final source = File(
      'windows/runner/desktop_clipboard_image_plugin.cpp',
    ).readAsStringSync();

    expect(source, contains('if (!clipboard.opened())'));
    expect(source, contains('IsClipboardFormatAvailable(CF_HDROP)'));
    expect(source, contains('IsClipboardFormatAvailable(CF_UNICODETEXT)'));
    expect(source, contains('if (!text.has_value())'));
    expect(source, contains('return std::nullopt;'));
  });
}
