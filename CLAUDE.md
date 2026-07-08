# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Two companion docs are authoritative and should be treated as part of these instructions:
- `AGENTS.md` — setup/verification commands, project structure, code style, security notes, and commit conventions.
- `DESIGN.md` — visual design system, color/typography tokens, and UI do's and don'ts.

This file focuses on the big-picture architecture that is not obvious from reading any single file.

## What this is

Whisper is a Flutter LAN-collaboration app (Android, macOS, Linux, Windows; iOS runner kept but untested) that moves text, files, clipboard, Android notifications, desktop system audio, and keyboard/mouse input between trusted devices on the same network over a direct WebSocket connection. It is **not** related to the OpenAI Whisper speech model. There is no end-to-end encryption — never describe transfers as secure against untrusted peers. `whisper-web/` is a separate Next.js 15 product site.

## Common commands

```bash
flutter pub get                                          # install deps
flutter analyze                                          # lint (CI gate)
flutter test                                             # all tests (CI gate)
flutter test test/<name>_test.dart                       # single test file
flutter run                                              # run on current platform
./script/build_and_run.sh                                # build+sign+run macOS debug app
./script/build_and_run.sh --verify                       # verify macOS build/sign/launch
./script/build_and_run.sh package-macos                  # package macOS DMG
./script/test_remote_input_keys.sh                       # remote-input key matrix suite

# Code generation — REQUIRED after the matching source change:
dart run build_runner build --delete-conflicting-outputs # after Drift schema edits
flutter gen-l10n                                          # after ARB (l10n) edits
```

`whisper-web/`: `cd whisper-web && npm install && npm run dev` (also `npm run build`, `npm run lint`).

## Architecture

The app is built around **singleton coordinators**, not a DI/Provider tree. Most subsystems expose a single shared instance (e.g. `WsSvrManager()` returns a global singleton) and UI/state talk to them directly. When extending a flow, reuse the existing coordinator/manager rather than introducing a parallel one.

### Networking core — `lib/socket/`
`WsSvrManager` (`svrmanager.dart`, ~4000 lines) is the central hub: it runs the `shelf` WebSocket server, manages outgoing client connections, drives the auth/trust handshake, and dispatches every message type (text, file transfer, clipboard, profile refresh, audio, remote input). A device can be both server and client to different peers simultaneously; per-peer state lives in `PeerConnectionRegistry` / `peer_connection.dart`. Key collaborators:
- `auth_request_gate.dart` — dedupes/serializes pending connection-confirmation requests.
- `whisper_frame_v3.dart` + `file_transfer_v3.dart` + `file_transfer_source.dart` + `peer_transfer_runtime.dart` — the framed, resumable multi-peer file-transfer protocol.

UI and app logic subscribe to networking events through the **`ISocketEvent` listener interface** (`onMessage`, `onAuth`, `onProgress`, `onTransferUpdated`, `onConnect`, `onClose`, …). This is the main seam between the socket layer and the rest of the app — add new cross-cutting events here.

### App state — `lib/state/`
Coordinators that sit above the socket layer: `connection_coordinator.dart` (connection lifecycle/models), `auto_connect_planner.dart`, `chat_session_list.dart`, `peer_profile.dart` (remote device profiles), `device_workspace_state.dart`, `resumable_transfer_window.dart`, `app_shutdown.dart`, `discovery_resolve_limiter.dart` (throttles mDNS resolution).

### Feature subsystems (self-contained, protocol + coordinator + platform bridge)
- `lib/audio/` — system-audio sharing. Capture → Opus codec → packet transport → fan-out to one or more playback sinks, with clock sync and channel/group roles. Entry points: `audio_share_coordinator.dart`, `audio_group_coordinator.dart`, `audio_share_manager.dart`.
- `lib/remote_input/` — keyboard/mouse sharing. Screen-topology/layout drives edge-crossing between devices; native bridges per platform (Linux is X11-only). Entry points: `remote_input_coordinator.dart`, `remote_input_workspace_coordinator.dart`, `remote_input_layout.dart`.

Each subsystem follows the same shape: a `*_protocol.dart` (wire format), a `*_coordinator.dart` / `*_manager.dart` (orchestration), a `*_packet_transport.dart`, and a `*_platform.dart` native abstraction. Prefer explicit protocol/state transitions over implicit side effects here.

### Data — `lib/model/`
Drift (SQLite) database in `LocalDatabase.dart`. `device.dart`, `message.dart` (`MessageEnum` typed messages), `file_transfer.dart` are the row models.

### Other
- `lib/page/` screens, `lib/widget/` reusable UI, `lib/helper/` platform helpers (files, clipboard sync, notifications, Android background service, FTP, desktop startup), `lib/theme/` (`AppTheme` + `WhisperPalette` tokens — see DESIGN.md), `lib/l10n/` ARB files (zh/en/es).
- `android/ ios/ macos/ linux/ windows/` native runners; platform-specific behavior should stay behind the helper/coordinator/native-plugin boundaries.

## Generated files — never hand-edit
- `lib/model/LocalDatabase.g.dart` → edit Drift source, run build_runner.
- `lib/l10n/app_localizations*.dart` → edit ARB files, run `flutter gen-l10n`.
- All user-facing strings must be localized via ARB; do not hardcode copy in widgets.

## Testing notes
`test/` (~105 files) leans heavily on **source-level tests** that assert platform integration and protocol behavior by reading the source, alongside unit/widget tests. When changing socket/transfer/audio/remote-input/db/state-machine code, add or update the focused test and run `flutter analyze` + `flutter test` before claiming readiness. If native platform behavior can't be verified locally, document the platform, the command not run, and the residual risk.

## Conventions
Conventional Commits with a concrete scope: `feat(remote-input): …`, `fix(db): …`, `chore: …`. Scopes seen here: `remote-input`, `audio`, `db`, `clipboard`, `socket`, `linux`, `windows`, `macos`, `android`, `ios`, `web`, `l10n`, `release`. Do not commit secrets; `keystore/whisper.keystore` is tracked but must not be rotated without approval. `WHISPER_REMOTE_INPUT_TRACE=1` enables verbose remote-input tracing.
