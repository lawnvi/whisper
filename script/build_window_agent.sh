#!/usr/bin/env bash
# Builds whisper-agent (android_agent/) into assets/window_stream/whisper-agent.jar
# with javac + d8, no Gradle, and writes the sidecar whisper-agent.json that
# test/window_stream_agent_sidecar_test.dart checks against the sources.
#
#   ./script/build_window_agent.sh           build, run the host tests
#   ./script/build_window_agent.sh --check   only verify the sidecar's source hash
#
# Pinned toolchain so the jar is reproducible: android-36 platform,
# build-tools 36.1.0, Java 11+ (targets Java 8 bytecode).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT="$ROOT/android_agent"
OUT_DIR="$ROOT/assets/window_stream"
JAR="$OUT_DIR/whisper-agent.jar"
SIDECAR="$OUT_DIR/whisper-agent.json"

PLATFORM=36
BUILD_TOOLS=36.1.0
SCRCPY_VERSION=5.0.1
AGENT_VERSION="$(sed -n 's/.*String VERSION = "\(.*\)";/\1/p' "$AGENT/src/com/vireen/whisper/agent/AgentMain.java")"
PROTOCOL="$(sed -n 's/.*int PROTOCOL_VERSION = \([0-9]*\);/\1/p' "$AGENT/src/com/vireen/whisper/agent/Wire.java")"

# Hash of every input file (dotfiles such as .DS_Store skipped): relative
# path, NUL, contents, in byte order of the paths. The Dart test computes the
# same value.
source_hash() {
  (
    cd "$ROOT"
    { find android_agent/src android_agent/upstream -type f ! -name '.*'; echo script/build_window_agent.sh; } \
      | LC_ALL=C sort \
      | while IFS= read -r file; do
          printf '%s\0' "$file"
          cat "$file"
        done
  ) | shasum -a 256 | cut -d' ' -f1
}

if [[ "${1:-}" == "--check" ]]; then
  expected="$(sed -n 's/.*"sourceSha256": "\([0-9a-f]*\)".*/\1/p' "$SIDECAR")"
  actual="$(source_hash)"
  if [[ "$expected" != "$actual" ]]; then
    echo "whisper-agent.jar is stale: run ./script/build_window_agent.sh" >&2
    exit 1
  fi
  echo "whisper-agent.jar matches its sources"
  exit 0
fi

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
PLATFORM_DIR="$SDK/platforms/android-$PLATFORM"
TOOLS_DIR="$SDK/build-tools/$BUILD_TOOLS"
ANDROID_JAR="$PLATFORM_DIR/android.jar"
FRAMEWORK_AIDL="$PLATFORM_DIR/framework.aidl"
LAMBDA_JAR="$TOOLS_DIR/core-lambda-stubs.jar"
for required in "$ANDROID_JAR" "$FRAMEWORK_AIDL" "$TOOLS_DIR/d8" "$TOOLS_DIR/aidl"; do
  if [[ ! -e "$required" ]]; then
    echo "missing $required (install platform android-$PLATFORM and build-tools $BUILD_TOOLS)" >&2
    exit 1
  fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/whisper-agent.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
GEN="$WORK/gen"
CLASSES="$WORK/classes"
mkdir -p "$GEN/com/genymobile/scrcpy" "$CLASSES" "$WORK/host"

cat > "$GEN/com/genymobile/scrcpy/BuildConfig.java" <<EOF
package com.genymobile.scrcpy;

public final class BuildConfig {
  public static final boolean DEBUG = false;
  public static final String VERSION_NAME = "$SCRCPY_VERSION";
}
EOF

echo "Host tests..."
javac -encoding UTF-8 -source 8 -target 8 -nowarn -Xlint:-options -d "$WORK/host" \
  "$AGENT/src/com/vireen/whisper/agent/Wire.java" \
  "$AGENT/src/com/vireen/whisper/agent/TouchGuardParser.java" \
  "$AGENT/src/com/vireen/whisper/agent/ProcNetParser.java" \
  "$AGENT/test/com/vireen/whisper/agent/WireTest.java" \
  "$AGENT/test/com/vireen/whisper/agent/TouchGuardParserTest.java" \
  "$AGENT/test/com/vireen/whisper/agent/ProcNetParserTest.java"
java -ea -cp "$WORK/host" com.vireen.whisper.agent.WireTest
java -ea -cp "$WORK/host" com.vireen.whisper.agent.TouchGuardParserTest
java -ea -cp "$WORK/host" com.vireen.whisper.agent.ProcNetParserTest

echo "AIDL..."
(
  cd "$AGENT/upstream/aidl"
  "$TOOLS_DIR/aidl" -o"$GEN" -I. android/content/IOnPrimaryClipChangedListener.aidl
  "$TOOLS_DIR/aidl" -o"$GEN" -I. -p "$FRAMEWORK_AIDL" android/view/IDisplayWindowListener.aidl
)

echo "Compiling..."
(
  cd "$AGENT"
  find upstream/java src -name '*.java' | LC_ALL=C sort > "$WORK/sources.txt"
  find "$GEN" -name '*.java' | LC_ALL=C sort >> "$WORK/sources.txt"
  javac -encoding UTF-8 -source 8 -target 8 -nowarn -Xlint:-options \
    -bootclasspath "$ANDROID_JAR" -cp "$LAMBDA_JAR" \
    -d "$CLASSES" @"$WORK/sources.txt"
)

echo "Dexing..."
(
  cd "$CLASSES"
  find . -name '*.class' | LC_ALL=C sort > "$WORK/classes.txt"
  "$TOOLS_DIR/d8" --release --min-api 29 --classpath "$ANDROID_JAR" \
    --output "$WORK/classes.zip" @"$WORK/classes.txt"
)

mkdir -p "$OUT_DIR"
cp "$WORK/classes.zip" "$JAR"
JAR_SHA="$(shasum -a 256 "$JAR" | cut -d' ' -f1)"
SOURCE_SHA="$(source_hash)"
cat > "$SIDECAR" <<EOF
{
  "agentVersion": "$AGENT_VERSION",
  "protocol": $PROTOCOL,
  "scrcpyVersion": "$SCRCPY_VERSION",
  "platform": "android-$PLATFORM",
  "buildTools": "$BUILD_TOOLS",
  "sourceSha256": "$SOURCE_SHA",
  "jarSha256": "$JAR_SHA"
}
EOF
echo "Wrote $JAR ($(wc -c < "$JAR" | tr -d ' ') bytes, sha256 $JAR_SHA)"
