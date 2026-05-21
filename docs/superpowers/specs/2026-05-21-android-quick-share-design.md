# Android Quick Share Design

## Goal

Allow Android users to choose Whisper from the system share sheet for files and media, then send the shared items to an already connected device.

## Scope

- Support Android only.
- Support file and media share intents backed by `Intent.EXTRA_STREAM`.
- Support both `ACTION_SEND` and `ACTION_SEND_MULTIPLE`.
- Do not register a text-only share target and do not handle text sharing in the first version.
- Only already connected peers can be selected as targets.
- Do not start a new connection, auto-connect, or authentication flow from the share sheet.

## User Flow

1. The user shares one or more files, images, videos, or audio items from another Android app.
2. Android shows Whisper as a share target.
3. Whisper opens to the device list with a pending quick-share state.
4. The user selects one currently connected device.
5. Whisper copies shared `content://` items into an app cache staging directory and sends each staged file through the existing file-transfer path.
6. If no connected devices are available, Whisper shows a localized unsupported-state message and clears the pending quick-share state.

## Android Intake

`MainActivity` receives share intents because it already uses `singleTop`. It must handle both cold-start and warm-start intents.

The activity extracts stream URIs from:

- `ACTION_SEND` with a single `Intent.EXTRA_STREAM`.
- `ACTION_SEND_MULTIPLE` with an `ArrayList<Uri>` in `Intent.EXTRA_STREAM`.

The Android bridge exposes the pending URI strings through a Flutter `MethodChannel`. Native code only captures and forwards URI identity; Flutter owns staging, target selection, and sending.

## Flutter Coordination

Add a focused quick-share coordinator/helper for Android. Its responsibilities are:

- Read pending shared URI strings from the Android bridge.
- Query display metadata where possible.
- Stage each URI into an app cache directory using a native bridge method that can open Android `ContentResolver` streams.
- Expose a pending quick-share state to `DeviceListScreen`.
- Send staged paths only after the user selects a connected peer.
- Clear staged state after successful handoff to `WsSvrManager.sendFile`.

The existing WebSocket and file-transfer protocol remain unchanged.

## Device Selection

`DeviceListScreen` should treat pending quick-share as a temporary selection mode. In that mode:

- Connected peers remain selectable.
- Disconnected or merely discovered peers are visible but not valid quick-share targets.
- Selecting a connected peer calls `socketManager.selectPeer(peerId)` and then sends the staged files.
- If the selected peer disconnects before send starts, the app shows a failure message and leaves normal device-list behavior intact.

## Errors

The feature should surface concise localized errors for:

- No file URI found in the incoming share intent.
- No connected devices available.
- Unable to read or stage one or more shared items.
- Selected peer is no longer connected.

The first version may fail the whole share batch if any item cannot be staged. This keeps the behavior predictable and avoids partial-send ambiguity.

## Testing

Use source-level tests for Android manifest and Kotlin intent handling because Android instrumentation is not part of this repository's normal test loop.

Use Dart unit/source tests for:

- Quick-share state and file-list handling.
- Connected-device-only target gating.
- Device-list source references to the quick-share flow.

Before broad readiness, run:

- `flutter test` for the focused tests.
- `flutter analyze`.
