# Monocypher

Ed25519 signature checks and SHA-512 for the Windows lock screen input
service, which updates itself only from files a signed manifest names
(`windows/runner/input_service_manifest.cpp`). Windows' own CNG has no
Ed25519, and the manifest is signed with the same key as update packages.

- Upstream: <https://monocypher.org>, version 4.0.2
  (`monocypher-4.0.2.tar.gz`, SHA-512 `bf275d4c…54dc084714`, the same on
  monocypher.org and the GitHub release).
- Files: `src/monocypher.c`, `src/monocypher.h` and
  `src/optional/monocypher-ed25519.{c,h}`, unchanged, in the same layout.
- Licence: BSD-2-Clause or CC0-1.0, at our choice (`LICENCE.md`).
- Built as its own C library in `windows/runner/CMakeLists.txt`, without the
  runner's `/W4 /WX`.
- Drop it if Windows gains Ed25519 in CNG, or if the service stops updating
  itself.
