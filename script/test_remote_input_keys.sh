#!/usr/bin/env bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

flutter test \
  test/remote_input_key_matrix_test.dart \
  test/remote_input_key_translation_test.dart \
  test/remote_input_native_source_test.dart \
  test/remote_input_text_shortcut_test.dart \
  test/remote_input_protocol_test.dart \
  test/remote_input_platform_test.dart
