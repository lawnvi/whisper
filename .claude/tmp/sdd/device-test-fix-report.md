# Device Test Fix Report

## F1 connection request notification debounce

- Commit: `5c1f0897aa35df5822094fd1680ec996d98a1cc5`
- Message: `fix(socket): 连接请求通知防抖,对端重试不再闪烁`
- Changed:
  - Added `ConnectionRequestNotificationDismissal` with per-peer delayed dismiss timers and cancel-on-new-request behavior.
  - `ConnectionRequestNotifier.dismissForPeer` now accepts `graceMillis`, defaults to immediate cancel, and uses delayed cancel for socket-close cleanup.
  - `maybeShowForAuthRequest` cancels pending delayed dismiss for the same peer and sets `onlyAlertOnce: true` for Android notification updates.
  - `svrmanager._releaseIncomingAuthForSink` now calls `dismissForPeer(peerId, graceMillis: 3000)`.
  - Guarded `onResolved` path still calls `dismissForPeer(peerId)` with default immediate cancel.
- TDD:
  - RED: `flutter test test/connection_request_notification_dismissal_test.dart` failed because `connection_request_notification_dismissal.dart` did not exist.
  - RED: `flutter test test/connection_request_notification_source_test.dart` failed because `onlyAlertOnce` and `graceMillis: 3000` were absent.
  - GREEN: `flutter test test/connection_request_notification_dismissal_test.dart test/connection_request_notification_source_test.dart`.

## F2 connection prompt dedupe

- Commit: `23ac2390970255154a08e281f6d7c0d08b0c4b0b`
- Message: `fix(socket): 连接请求弹窗按设备去重,外部处理后自动关闭`
- Changed:
  - Added `ConnectPromptRegistry` for per-peer prompt callback rebinding and external close handling.
  - `deviceList.onAuth` now registers server-side empty-message auth prompts by peer, shows only one `showCupertinoDialog`, and buttons always invoke `latestCallbackFor(peerId)`.
  - `deviceList.afterAuth` now calls `resolveAndClose(deviceData.uid)` before auth result branching, so notification-side accept/reject closes any visible prompt.
- TDD:
  - RED: `flutter test test/connect_prompt_registry_test.dart` failed because `connect_prompt_registry.dart` did not exist.
  - RED: `flutter test test/connect_prompt_device_list_source_test.dart` failed because deviceList did not import/use the registry or close prompts in `afterAuth`.
  - GREEN: `flutter test test/connect_prompt_registry_test.dart test/connect_prompt_device_list_source_test.dart test/auth_request_gate_source_test.dart test/outgoing_file_message_ui_source_test.dart`.

## F3 transfer notification throttle

- Commit: `0c56b582fbeef23bdab85513d6c7b7583b909655`
- Message: `fix(android): 传输进度通知提高到 300ms 节流`
- Changed:
  - `TransferNotificationAggregator._throttleMillis` changed from `1000` to `300`.
  - Throttle test now asserts 100ms is suppressed and 350ms is emitted.
- TDD:
  - RED: `flutter test test/transfer_notification_aggregator_test.dart` failed because 350ms still returned `null` under the old 1000ms throttle.
  - GREEN: `flutter test test/transfer_notification_aggregator_test.dart`.

## Final verification

- `flutter analyze`: passed, no issues found.
- `flutter test`: passed, 526 tests passed.
- Worktree after commits: only local untracked `.claude/` and `CLAUDE.md` remain.

## F4 transfer chip icon-only

- Commit: `51ec3d8bc8c2538b4c24857362e26849fc6cf5a0`
- Message: `fix(android): 传输 chip 图标化,规避挖孔遮挡`
- Changed:
  - Removed `builder.setShortCriticalText("$clamped%")` from `TransferForegroundService.kt`.
  - Kept `NotificationCompat.ProgressStyle`, `setRequestPromotedOngoing(true)`, and the classic `setProgress` fallback unchanged.
  - Added a source test reverse assertion that `TransferForegroundService.kt` must not contain `setShortCriticalText`.
- TDD:
  - RED: `flutter test test/transfer_notification_source_test.dart` failed while `setShortCriticalText` was still present.
  - GREEN: `flutter test test/transfer_notification_source_test.dart`.
- Verification:
  - `flutter analyze`: passed, no issues found.
  - `flutter test`: passed, 526 tests passed.
  - `flutter build apk --debug`: passed, built `build/app/outputs/flutter-apk/app-debug.apk`.
