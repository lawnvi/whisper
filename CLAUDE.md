# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

`AGENTS.md` above holds the commands, project structure, code organization and style, testing rules, security notes and commit conventions. `DESIGN.md` is the only source of UI rules: grammar, tokens, do's and don'ts. Read it before any UI work. Start at `docs/design/README.md` when implementing the redesign: it links `surfaces.md` (per-screen specs), `flutter.md` (tested code), `migration.md` (the steps and what each one delivered), `decisions.md` (why, what was rejected, what is open) and the local prototype. Feature specs must not define visual values.

What follows is the big-picture architecture that is not obvious from reading any single file.

## What this is

Whisper is a Flutter LAN-collaboration app (Android, macOS, Linux, Windows; iOS runner kept but untested) that moves text, files, clipboard, Android notifications, desktop system audio, and keyboard/mouse input between trusted devices on the same network over a direct WebSocket connection. Trusted devices can also browse and mount each other's files and show each other's windows and apps (window flow); share links serve files to browsers on the LAN. It is **not** related to the OpenAI Whisper speech model. Authenticated application data uses X25519 and XChaCha20-Poly1305; discovery metadata and local storage are not encrypted, and the implementation has not had an independent cryptographic audit. `whisper-web/` is a separate Next.js 15 product site.

## Architecture

The app is built around **singleton coordinators**, not a DI/Provider tree. Most subsystems expose a single shared instance (e.g. `WsSvrManager()` returns a global singleton) and UI/state talk to them directly. When extending a flow, reuse the existing coordinator/manager rather than introducing a parallel one.

### Networking core — `lib/socket/`
`WsSvrManager` (`svrmanager.dart`, ~4000 lines) is the central hub: it runs the `shelf` WebSocket server, manages outgoing client connections, drives the auth/trust handshake, and dispatches every message type (text, file transfer, clipboard, profile refresh, audio, remote input). A device can be both server and client to different peers simultaneously; per-peer state lives in `PeerConnectionRegistry` / `peer_connection.dart`. Key collaborators:
- `auth_request_gate.dart` — dedupes/serializes pending connection-confirmation requests.
- `whisper_frame_v3.dart` + `file_transfer_v3.dart` + `file_transfer_source.dart` + `peer_transfer_runtime.dart` — the framed, resumable multi-peer file-transfer protocol.
- `folder_transfer_*.dart` — a folder travels through that same protocol as one byte stream (manifest, then each file followed by a status-and-SHA-256 trailer). Only the two ends differ: `folder_transfer_source.dart` reads the stream and `folder_transfer_sink.dart` writes it, each in a worker isolate. Small files are checked in memory and handed to `folder_write_pool.dart`, which writes them from a few isolates at once, so a checkpoint only covers the stream up to the first file not yet on disk. Offers carry the checksum algorithm `sha256-folder-v1`, which older peers reject instead of saving the stream as a file.

UI and app logic subscribe to networking events through the **`ISocketEvent` listener interface** (`onMessage`, `onAuth`, `onProgress`, `onTransferUpdated`, `onConnect`, `onClose`, …). This is the main seam between the socket layer and the rest of the app — add new cross-cutting events here.

### App state — `lib/state/`
Coordinators that sit above the socket layer: `connection_coordinator.dart` (connection lifecycle/models), `auto_connect_planner.dart`, `chat_session_list.dart`, `peer_profile.dart` (remote device profiles), `resumable_transfer_window.dart`, `app_shutdown.dart`, `discovery_resolve_limiter.dart` (throttles mDNS resolution).

### Feature subsystems (self-contained, protocol + coordinator + platform bridge)
- `lib/audio/` — system-audio sharing. Capture → Opus codec → packet transport → fan-out to one or more playback sinks, with clock sync and channel/group roles. Entry points: `audio_share_coordinator.dart`, `audio_group_coordinator.dart`, `audio_share_manager.dart`.
- `lib/remote_input/` — keyboard/mouse sharing. Screen-topology/layout drives edge-crossing between devices; native bridges per platform (Linux: XTest on X11, Mutter or the desktop portal with libei on Wayland). Entry points: `remote_input_coordinator.dart`, `remote_input_workspace_coordinator.dart`, `remote_input_layout.dart`.
- `lib/window_stream/` — window flow: one device's windows or apps shown and controlled on another. Desktops are sources through `remote/window_stream_host.dart`; Android phones through adb and the bundled agent (`android_agent/`, rebuilt by `script/build_window_agent.sh`). Capture/encode/decode/display are native in the FFI plugin `packages/window_stream_native/` (Linux sources need Wayland: GNOME plus the GNOME Shell helper, or KDE Plasma through a KWin script and KWin's own protocols). Entry point: `window_stream_coordinator.dart`.
- `lib/remote_files/` — cross-device file browser over the FileBrowse protocol (`fs_protocol.dart`, `fs_host.dart`, `fs_client.dart`, `fs_copies.dart`). `mount/` puts another device's files in the system file manager: a loopback NFSv3 server on macOS, FUSE on Linux, Cloud Files on Windows (`windows/cloud_files/`); file reads travel as `browseData` frames, and each mount runs in its own isolate so Whisper never blocks on its own mount. Mounts are writable when the host allows changes ("允许修改我的文件"): `MountTree` sends writes as `browseWrite` frames into an upload, a hidden copy beside the file (`fs_host_uploads.dart`) that closing renames into place; Windows has no write callback, so the sync root is watched and changed files are sent whole. Entry point: `mount/remote_mounts.dart`.
- `lib/share_links/` — share links for devices without Whisper: a LAN-only HTTP server that runs only while a link is on. Entry points: `share_link_store.dart`, `share_server.dart`.

Each subsystem follows the same shape: a `*_protocol.dart` (wire format), a `*_coordinator.dart` / `*_manager.dart` (orchestration), a `*_packet_transport.dart`, and a `*_platform.dart` native abstraction. Prefer explicit protocol/state transitions over implicit side effects here.

### Data — `lib/model/`
Drift (SQLite) database in `LocalDatabase.dart`. `device.dart`, `message.dart` (`MessageEnum` typed messages), `file_transfer.dart` are the row models.

### Other
- `lib/new_ui/` the interface (shell, phone, settings, files, sound, input, tray), `lib/page/` screens and the page-level logic behind it, `lib/widget/` reusable UI, `lib/helper/` platform helpers (files, clipboard sync, notifications, Android background service, desktop startup), `lib/theme/` (`AppTheme` + `WhisperPalette` tokens — see DESIGN.md), `lib/l10n/` ARB files (zh/en/es).
- `android/ ios/ macos/ linux/ windows/` native runners; platform-specific behavior should stay behind the helper/coordinator/native-plugin boundaries.
