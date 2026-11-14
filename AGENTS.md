# AGENTS.md

## Project Overview

- Project: Whisper, a Flutter-based LAN collaboration app for nearby devices.
- Purpose: send text, files, clipboard content, Android notifications, desktop system audio, and keyboard/mouse input between trusted devices on the same local network.
- Primary users: people moving work between their own computers and phones without a public relay.
- Platforms: Android, macOS, Linux, Windows, and a Next.js product site under `whisper-web/`.
- Important constraints: transfers stay on the LAN, authenticated application data is encrypted end to end (discovery metadata and local storage are not), Linux discovery depends on Avahi, Linux audio depends on PulseAudio or PipeWire Pulse, and Linux keyboard/mouse sharing works on X11 (XTest) and on GNOME Wayland (Mutter, no prompt); other Wayland desktops go through the desktop portal, which asks once.

## Setup Commands

- Install Flutter dependencies: `flutter pub get`
- Regenerate Drift database code after schema changes: `dart run build_runner build --delete-conflicting-outputs`
- Regenerate localizations after ARB changes: `flutter gen-l10n`
- Run the Flutter app on the current platform: `flutter run`
- Run the signed macOS debug app used by this repo: `./script/build_and_run.sh`
- Run macOS debug under LLDB: `./script/build_and_run.sh --debug`
- Stream macOS app logs/telemetry: `./script/build_and_run.sh --logs`
- Package a macOS DMG: `./script/build_and_run.sh package-macos`
- Install product-site dependencies: `cd whisper-web && npm install`
- Start the product site: `cd whisper-web && npm run dev`
- Build the product site: `cd whisper-web && npm run build`

## Verification Commands

- Analyze Dart/Flutter code: `flutter analyze`
- Check that no file grew past its size limit: `dart run tool/check_sizes.dart`
- Run all Flutter tests: `flutter test`
- Run one focused test: `flutter test test/<name>_test.dart`
- Run the remote-input key matrix suite: `./script/test_remote_input_keys.sh`
- Verify the macOS app builds, signs, launches, and has a running process: `./script/build_and_run.sh --verify`
- Check product-site linting when working in `whisper-web/`: `cd whisper-web && npm run lint`

CI runs `flutter pub get`, `flutter analyze`, the size check, a check that generated localizations are up to date, and `flutter test` on pull requests and pushes to `main`.

## Project Structure

- `lib/main.dart`: Flutter entry point, locale/theme bootstrapping, desktop window initialization.
- `lib/page/`: main screens such as device discovery, conversation, app list, and settings.
- `lib/widget/`: reusable UI pieces for chat, composer, banners, dialogs, and desktop workspace layout.
- `lib/state/`: app state coordinators for connections, auto-connect, sessions, transfers, shutdown, and discovery throttling.
- `lib/socket/`: WebSocket server/client orchestration, auth flow, message dispatch, file transfer, profile refresh, audio, and remote input routing. File path validation, portable names, and verified publication are separated into `file_path_policy.dart`, `transfer_file_name.dart`, and `verified_file_publisher.dart`.
- `lib/model/`: Drift database, device/message/transfer models, and generated database code.
- `lib/audio/`: audio sharing protocol, codecs, capture/playback abstractions, transport, and runtime coordinator.
- `lib/remote_input/`: keyboard/mouse sharing protocol, topology/layout, native platform bridges, transport, and coordinator.
- `lib/window_stream/`: window flow — protocol models, coordinator, this device as a source (`remote/`), adb and the Android agent link (`adb/`, `android/`), GNOME helper installer (`linux/`), and the frame pipeline. Capture, encoding, and display are native, in the FFI plugin `packages/window_stream_native/`; the phone-side agent is `android_agent/`, rebuilt with `./script/build_window_agent.sh` after any change.
- `lib/remote_files/`: cross-device file browser — the FileBrowse protocol, host and client, copies, and `mount/` for mounting another device's shared folders (macOS NFS server, Linux FUSE, Windows Cloud Files through `windows/cloud_files/`), each mount in its own isolate.
- `lib/share_links/`: LAN share links — the HTTP file server (port 10003 by default, only while a link is on), link store, routes, passwords, pages, and streamed zips.
- `lib/widget/island/`: the in-app island that gathers transfers, copies, audio, and window flow activity.
- `lib/helper/`: platform helpers for files, settings, notifications, background services, desktop startup, and general utilities.
- `lib/l10n/`: ARB files and generated Flutter localization classes for Chinese, English, and Spanish.
- `lib/theme/`: Material 3 theme and `WhisperPalette` tokens.
- `android/`, `ios/`, `macos/`, `linux/`, `windows/`: native runners and platform plugins.
- `test/`: Flutter tests of behavior: protocols, transfers, state machines and the logic behind the UI. Don't add tests that assert layout or the text of source files; a few source checks stay for what nothing can run here (release workflows, manifests, native log privacy, FFI entry points). `test/manual/` holds scripts that render screens and aren't part of `flutter test`.
- `script/`: local build, run, signing, packaging, and focused test helpers.
- `.github/workflows/`: CI and multi-platform release packaging.
- `docs/`: user guide and troubleshooting (Chinese and English), plus `docs/README.md`, which says where every kind of document goes.
- `docs/design/`: companions to `DESIGN.md`, starting at `README.md`: per-screen specs, Flutter recipes, migration steps, decisions, the local prototype, reference screenshots and check tools.
- `docs/internals/`: how a subsystem works now, for developers. `docs/records/`: dated test results, reviews and research, never updated.
- `docs/superpowers/`: earlier design specs and implementation plans, read-only history. Their UI sections are history; `DESIGN.md` wins.
- `whisper-web/`: Next.js 15 product introduction site.

## Generated And Large Files

- Do not hand-edit `lib/model/LocalDatabase.g.dart`; update the Drift source and run build runner.
- Do not hand-edit `lib/l10n/app_localizations*.dart`; update the ARB files and run `flutter gen-l10n`.
- Treat Flutter generated plugin registrants under platform folders as generated unless the platform tooling requires a manual change.
- Avoid touching `build/`, `.dart_tool/`, `.flutter-plugins-dependencies`, `dist/`, and other local build outputs.
- `pubspec.lock` is tracked for this app; update it only as part of dependency changes.

## Code Style

- Follow the existing Flutter/Dart style and `flutter_lints` baseline in `analysis_options.yaml`.
- Keep platform-specific behavior behind the existing helper, coordinator, or native plugin boundaries.
- Prefer explicit protocol/state transitions over implicit side effects, especially in `lib/socket/`, `lib/audio/`, `lib/remote_input/`, `lib/window_stream/`, and `lib/remote_files/`.
- Keep UI strings localized through ARB files; avoid adding hardcoded user-facing copy in widgets.
- Use existing singleton coordinators and managers when extending current flows; introduce new abstractions only when they reduce real duplication.
- Follow `DESIGN.md` for all UI. The code has not migrated yet: see `docs/design/README.md`. New UI uses the tokens in `docs/design/flutter.md`; do not write raw values in widgets.
- Add concise comments only for non-obvious protocol, platform, or concurrency behavior.

## Code Organization

The code base grew by adding to whatever file was nearest. These rules stop that; `dart run tool/check_sizes.dart` enforces the first one in CI.

- **Size.** A Dart file stays under 1000 lines, a native file (Swift, C/C++, Kotlin, Java) under 1500. Files already over it are listed in `tool/size_baseline.txt` and may only shrink: split before adding to them, then run `dart run tool/check_sizes.dart --update`. Aim for functions under 60 lines; one over 150 lines is a split waiting to happen.
- **One job per file.** A new feature gets its own files in its subsystem instead of a section in a big one. `lib/socket/svrmanager.dart` only connects and routes: a new message type is handled by its subsystem's coordinator. Pages assemble widgets; what decides what is sent or started lives in a coordinator or controller beside them.
- **One native plugin per file.** `macos/Runner/MainFlutterWindow.swift` sets up the window and registers plugins; each plugin's code lives in its own file. The same goes for the Windows and Linux runners.
- **Write it once.** Logic that every platform needs goes in Dart, with only the system calls in native code. Before writing a helper, search for an existing one; a block copied a second time gets extracted.
- **UI reaches the network through `WsSvrManager` and `ISocketEvent`.** Don't import other `lib/socket/` internals from `lib/page/`, `lib/new_ui/` or `lib/widget/`; a few still do and are moved when touched.
- **No copies of production code.** A probe or tool uses the real sources or is deleted after use; it never keeps a copy that drifts.
- **Third-party source** lives in its own directory (`android_agent/upstream/`, `third_party/`) with a note on the upstream version, license, any patches and when to drop it. It doesn't count towards sizes and is never edited in place without that note.

## Documentation

`docs/README.md` holds the rules and the index. In short:

- A change users can see updates `docs/user-guide.md` and `docs/user-guide_en.md` in the same commit, and `README.md` with `README_en.md` when it changes what the app does or where it runs. The two languages say the same thing.
- A new subsystem or a new way of doing something gets a page in `docs/internals/`, changed with the code and deleted when the approach goes. Measurements and comparisons made along the way go in `docs/records/YYYY-MM-DD-<topic>.md` and are not edited afterwards.
- Write paths and class names, not line numbers. Say what was not tested.
- User docs use the names on screen, never class names, protocol fields or test files.

## Changing A Protocol Or The Database

- **Wire format.** A peer's profile rejects unknown fields, so a new field or message is sent only to peers whose protocol version knows it (see `formFactor` in `lib/state/peer_profile.dart`). Say what an older peer does with it, and when versions can't work together, tell the user which device to update. Keep the test for older and newer peers.
- **Database.** Bump the schema version, make the migration step idempotent, regenerate with build_runner, and test both a fresh database and an upgrade from the previous version.

## Testing Instructions

Tests are for what would break quietly and cost a lot. They are not a record of the work. Most checks made while working are temporary: run them, then throw them away.

**What stays in `test/`:** if this broke, would someone lose data or security, or would a device do the wrong thing, with nothing on screen to show it?
- Wire formats and protocols. A format or protocol that changes keeps a test for what older or newer peers do with it.
- Authentication, trust and security boundaries: tampering, replay, leaving an allowed path, permissions, what a visitor on the LAN can reach.
- Data safety: transfer integrity and resume, not overwriting or losing someone's files, database migrations.
- State machines that decide what is sent, started or stopped: connection, transfer, audio, remote input. This counts wherever the logic lives, including behind a page. Logic that only decides what a screen shows does not count.
- One test per main path over real sockets and real files: connecting, sending a file or folder, mounting, a share link. These catch what unit tests with stand-ins miss, so prefer them to more unit tests of the same path.
- Stress and performance tests that guard a number. Guard what does not depend on the machine (queue depth, bounds, nothing lost under load) or leave a wide margin. A benchmark that only reports goes in `test/manual/`.
- A regression test for a real bug that was hard to find and would come back silently. Say in a comment what the bug was.

**What is temporary:** anything else that proves a change works while it is being made, such as a throwaway test, a probe or a script. Run it and delete it before committing. Scripts worth running again by hand go in `test/manual/`, which `flutter test` does not run.

**What does not get written at all:**
- Layout, colors, sizes, wording or screenshots. Look at the screen instead, with the render scripts in `test/manual/`.
- The text of source files. The only exceptions are what nothing can run here: release workflows, manifests, native log privacy, FFI entry points, security checks in privileged or native code that tests cannot exercise, and a single workaround whose loss would only show on a platform or network that tests cannot reach, with a comment saying what breaks.
- Tests that restate the implementation, that only exercise a stand-in, or that cover what another test already covers.
- Tests of test helpers or of tools that are not shipped.

**Keeping the number down:**
- A change adds no long-lived test by default, including changes to core code. Add one only if you can say what would break that nothing else would catch. A new or changed wire format always qualifies. Prefer extending an existing test to adding a file.
- One test per rule, not per input: inputs of the same rule go in one table.
- UI changes add none, unless the logic behind them is on the list above.
- When a feature goes, its tests go with it. When a test gets in the way of a refactor without catching a bug, delete it.

**Running them:**
- Start with the narrowest test that covers the changed behavior.
- Before claiming broad readiness, run `flutter analyze` and `flutter test`.
- If native platform behavior cannot be verified locally, document the platform, command not run, and residual risk.

## Security And Privacy Notes

- `AppLog` is what users send when something is wrong. Only `PrivacyLog` events and the type, code and place of errors go in. Never pass it `error.toString()`, message text, file names or device names.
- Authenticated sessions use X25519 and XChaCha20-Poly1305; discovery metadata remains visible and local storage is not encrypted. The implementation has not had an independent cryptographic audit; do not claim complete protection against untrusted peers.
- Do not add public relay behavior without an explicit design and security review.
- Do not commit new secrets, tokens, signing identities, private keys, or local credentials.
- The existing `keystore/whisper.keystore` is tracked; do not replace or rotate it without explicit approval.
- Release signing uses GitHub secrets such as `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD`, `MACOS_KEYCHAIN_PASSWORD`, `KEY_PASSWORD`, and `STORE_PASSWORD`.
- Every release package gets a `<package>.sig` from `UPDATE_SIGNING_KEY` (Ed25519, `script/sign_update_packages.sh`). The app's updater installs nothing without a valid one from a key in `lib/helper/update_signature.dart`, so a mirror or a changed release listing can't push code. Changing that key means first shipping a version that trusts both.
- macOS releases are signed with the hardened runtime (`sign_app` in `script/build_and_run.sh`). Library validation is off only because the signing identity has no team ID. Never add `com.apple.security.cs.allow-dyld-environment-variables` or `com.apple.security.get-task-allow` to release entitlements: any program of the user could then act with Whisper's Accessibility and Screen Recording grants.
- Local macOS signing can use `WHISPER_MACOS_*` environment variables from `script/build_and_run.sh`; never include secret values in docs or commits.
- `WHISPER_REMOTE_INPUT_TRACE=1` enables verbose remote-input tracing and may expose device/session details in logs.
- The optional Windows lock screen input service (`windows/runner/input_service.cpp`) is `whisper.exe` itself, copied into Program Files and run as LocalSystem. By default it only injects while the session is locked. UAC prompts and administrator windows on the unlocked desktop are reachable only when an administrator turns on `HKLM\SOFTWARE\Whisper\InputService\AllowElevated` (the switch in Settings); a request can never widen that. Don't widen it further, or run it from a user-writable folder, without an explicit security review. Its roles must return from `wWinMain` before anything touches Flutter, which is delay-loaded so the copy can start on its own.
- That service updates itself from the app's folder, which the user can write to (`windows/runner/input_service_update.cpp`): only files named in `whisper_input_service.manifest`, signed in the release workflow by `script/sign_input_service.sh` with `UPDATE_SIGNING_KEY`, strictly newer than the running build, every SHA-512 matching. Its keys in `input_service_manifest.cpp` must stay the same as `lib/helper/update_signature.dart`'s. Elevated roles other than installing run the Program Files copy, never the app's own `whisper.exe`. Only installing still elevates the app's copy, once, when the user asks for the service.

## Collaboration Rules

- Preserve user changes and unrelated worktree modifications.
- Do not run destructive git commands unless explicitly requested.
- Ask before publishing releases, deploying the web site, uploading artifacts, deleting data, or changing signing assets.
- Keep changes scoped to the requested behavior and summarize changed files plus verification results at the end.
- Use Conventional Commit style seen in this repo, for example `feat(remote-input): ...`, `fix(db): ...`, and `chore: ...`.
- Required merge checks should include at least `flutter analyze` and `flutter test`; release/package changes should also exercise the relevant platform script or workflow logic.

## Commit And PR Conventions

- Commit message format: `<type>(<scope>): <subject>`.
- Allowed commit types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.
- Use a short, concrete scope such as `remote-input`, `audio`, `db`, `linux`, `windows`, `macos`, `android`, `ios`, `web`, `l10n`, or `release`.
- Keep the subject concise and behavior-focused, for example `fix(db): make remote input layout migration idempotent`.
- PR descriptions should call out user-visible behavior, platform impact, tests run, and any release/signing considerations.

## Useful Codex Skills

- Use Flutter/macOS skills when changing macOS window behavior, signing, entitlements, packaging, or native Swift runner code.
- Use React/Next.js frontend guidance when changing `whisper-web/`.
- Use systematic debugging for test failures, platform regressions, or connection/transfer bugs.
- Multi-agent orchestration can be useful for independent platform slices because the repo has CI and many tests, but avoid heavy orchestration for vague work or changes that cross shared socket/protocol contracts.
