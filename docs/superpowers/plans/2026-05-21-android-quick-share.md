# Android Quick Share Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Android system share target that sends shared files or media to an already connected Whisper peer.

**Architecture:** Android `MainActivity` receives file/media share intents and forwards URI strings to Flutter through a small MethodChannel bridge. Flutter owns pending-share state, stages Android `content://` items into cache files, gates target selection to connected peers, and reuses `WsSvrManager.sendFile()` for transfer.

**Tech Stack:** Flutter/Dart, Android Kotlin, Android `ContentResolver`, Flutter MethodChannel, existing WebSocket file transfer.

---

### Task 1: Android Share Intent Contract

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `android/app/src/main/kotlin/com/vireen/whisper/MainActivity.kt`
- Test: `test/android_quick_share_source_test.dart`

- [ ] **Step 1: Write the failing source test**

Create a test that asserts the manifest declares `ACTION_SEND` and `ACTION_SEND_MULTIPLE` filters for stream MIME types, and that `MainActivity.kt` handles cold and warm intents.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `flutter test test/android_quick_share_source_test.dart`

Expected: fail because the intent filters and Kotlin share-intent bridge do not exist yet.

- [ ] **Step 3: Add manifest filters and Kotlin intent parsing**

Add file/media share filters under `MainActivity`. In `MainActivity.kt`, store pending stream URI strings from `intent` and `onNewIntent`, expose them through a MethodChannel, and clear them once consumed.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run: `flutter test test/android_quick_share_source_test.dart`

Expected: pass.

### Task 2: Dart Quick Share Coordinator

**Files:**
- Create: `lib/helper/android_quick_share.dart`
- Modify: `android/app/src/main/kotlin/com/vireen/whisper/MainActivity.kt`
- Test: `test/android_quick_share_test.dart`

- [ ] **Step 1: Write failing Dart tests**

Cover pending URI state, connected-target filtering, and staging failure behavior without depending on a live Android device.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `flutter test test/android_quick_share_test.dart`

Expected: fail because the Dart helper does not exist.

- [ ] **Step 3: Implement the helper**

Add a singleton coordinator that reads pending URI strings from `com.vireen.whisper/android_quick_share`, asks native code to stage URI contents into cache files, tracks staged paths, exposes `hasPendingShare`, filters connected targets, and clears state.

- [ ] **Step 4: Add native staging method**

In `MainActivity.kt`, add a MethodChannel method that copies each content URI to a cache subdirectory using `ContentResolver.openInputStream`, deriving a stable filename from `OpenableColumns.DISPLAY_NAME` when available.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run: `flutter test test/android_quick_share_test.dart test/android_quick_share_source_test.dart`

Expected: pass.

### Task 3: Device List Integration

**Files:**
- Modify: `lib/page/deviceList.dart`
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_zh.arb`
- Modify: `lib/l10n/app_es.arb`
- Test: `test/android_quick_share_device_list_source_test.dart`

- [ ] **Step 1: Write failing source test**

Assert `DeviceListScreen` imports the quick-share helper, loads pending share state during startup, gates quick-share sends with `socketManager.isConnectedTo`, and calls `socketManager.sendFile`.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `flutter test test/android_quick_share_device_list_source_test.dart`

Expected: fail because the device list is not wired to quick share.

- [ ] **Step 3: Wire mobile selection mode**

Load pending Android share state after the local device bootstrap. When pending files exist and no connected peers exist, show a localized toast and clear the pending state. When the user taps a connected peer, select that peer and send each staged file through `sendFile`. If a non-connected peer is tapped during pending share mode, show a localized connected-device-required toast.

- [ ] **Step 4: Add localization strings**

Add concise English, Chinese, and Spanish strings for pending share, no connected device, connected-device-required, and share staging failure.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run: `flutter test test/android_quick_share_device_list_source_test.dart test/android_quick_share_test.dart test/android_quick_share_source_test.dart`

Expected: pass.

### Task 4: Verification

**Files:**
- No production file changes expected.

- [ ] **Step 1: Run analyzer**

Run: `flutter analyze`

Expected: no new analyzer errors.

- [ ] **Step 2: Run full test suite**

Run: `flutter test`

Expected: all tests pass.

---

## Self-Review

- Spec coverage: Android share registration, cold/warm intent parsing, connected-only selection, staging, sending through existing file transfer, and error states are covered.
- Placeholder scan: no `TBD` or unspecified implementation steps remain.
- Type consistency: the plan uses one helper name, `AndroidQuickShare`, and one MethodChannel name, `com.vireen.whisper/android_quick_share`.
