#!/usr/bin/env bash
# Offline parser tests without building the app's native frameworks.
# Requires a Kotlin CLI distribution and the JUnit 4, Hamcrest and
# kotlinx-serialization-core JVM jars. No tools or dependencies are downloaded.
#
# KOTLIN_HOME=/path/to/kotlinc \
# TTML_TEST_CLASSPATH=/path/to/junit.jar:/path/to/hamcrest.jar:/path/to/serialization-core.jar \
# bash scripts/check-ttml.sh
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
: "${KOTLIN_HOME:?Set KOTLIN_HOME to a Kotlin CLI distribution}"
: "${TTML_TEST_CLASSPATH:?Supply JUnit 4, Hamcrest and kotlinx-serialization-core JVM jars}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

main="$repo/shared/src/commonMain/kotlin/com/music/bitchord/data/lyrics"
tests="$repo/shared/src/commonTest/kotlin/com/music/bitchord/data/lyrics"
classpath="$KOTLIN_HOME/lib/kotlin-test.jar:$KOTLIN_HOME/lib/kotlin-test-junit.jar:$TTML_TEST_CLASSPATH"
"$KOTLIN_HOME/bin/kotlinc" \
  "$main/TtmlLyrics.kt" "$main/LyricLine.kt" "$main/LyricAlignments.kt" \
  "$main/LyricGaps.kt" "$main/SyllableRuns.kt" "$main/EnhancedLrc.kt" \
  "$main/LyricsMatching.kt" "$main/LyricsQuery.kt" \
  "$tests/TtmlDuetTest.kt" "$tests/TtmlMarkupTest.kt" \
  -cp "$classpath" -d "$scratch/tests.jar"
java -cp "$scratch/tests.jar:$KOTLIN_HOME/lib/kotlin-stdlib.jar:$classpath" \
  org.junit.runner.JUnitCore \
  com.music.bitchord.data.lyrics.TtmlDuetTest \
  com.music.bitchord.data.lyrics.TtmlMarkupTest
