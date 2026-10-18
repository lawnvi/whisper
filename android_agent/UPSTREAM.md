# Upstream

`upstream/` is the server component of [scrcpy](https://github.com/Genymobile/scrcpy)
5.0.1 (commit a60891aea193d92e7e5c3942700eca63f9d19a5f), copied **unmodified**
from `server/src/main/` (`java/`, `aidl/`). It is licensed under the Apache
License 2.0 (`upstream/LICENSE`).

whisper-agent (`src/com/vireen/whisper/agent/`) only calls into it — device
wrappers, `FakeContext`, `Workarounds`, `Streamer`, codecs — and never patches
it, so moving to a newer scrcpy release means replacing `upstream/` and
rebuilding. Patches applied to upstream files: none.

Build: `script/build_window_agent.sh` (javac + d8, no Gradle) writes
`assets/window_stream/whisper-agent.jar` and its sidecar
`whisper-agent.json`; `test/window_stream_agent_sidecar_test.dart` checks that
the committed jar matches the sources.
