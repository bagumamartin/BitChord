#!/bin/bash
# AutoMix: the planner's rules, and the scorecard over the owner's real pairs.
#
# The rule cases are Rust tests. The scorecard reads the app's own stream cache
# (read-only, titles only) and plans twelve pairs through the same entry the app
# calls, so it measures the planner on real audio rather than on fixtures.
#
# The corpus half runs in --release: the beat and vocal models are ONNX graphs,
# and in a debug profile one three-minute track takes minutes instead of a
# second, which makes the check unusable rather than thorough.
#
# Run: scripts/check-automix.sh            (corpus at the default cache path)
#      AUTOMIX_CORPUS=/path scripts/check-automix.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
cd "$repo/native-core" || exit 2

cargo test --lib analyzer::plan::tests::effect_earned_only_for_a_real_clash || exit 1
cargo test --lib analyzer::plan::tests::a_five_percent_gap_keeps_the_analysed_blend || exit 1
cargo test --lib analyzer::plan::tests::a_true_beatmatch_still_blends || exit 1
cargo test --lib analyzer::plan::tests::mismatched_tempos_get_a_dj_technique_not_a_fade || exit 1
cargo test --lib analyzer::plan::tests::a_spent_effect_budget_keeps_the_blend || exit 1
# E-2: a cold ending keeps its phrase and holds the final chord at unity.
cargo test --lib analyzer::plan::tests::pair_five_keeps_its_phrase_and_holds_the_final_chord || exit 1
cargo test --lib analyzer::plan::tests::a_cold_ending_keeps_its_effect_inside_the_decay || exit 1

# B: the rendered handover. Every style is mixed through the production gain
# curves, the arm-time prime and the real effect, and the floor is checked in
# numbers rather than left to a listen.
ramp="$(cargo test --lib mixer::tests::mix_into_ramps_between_chunk_targets 2>&1)" || {
  echo "$ramp" | tail -20
  exit 1
}
echo "ok   the fade gain walks between chunk targets, no step"
handover="$(cargo test --lib mixer::tests::every_style_has_no_hole_at_the_handover -- --nocapture 2>&1)" || {
  echo "$handover" | tail -30
  exit 1
}
echo "$handover" | grep -E '^(EchoOut|LoopRoll|ReverbWash|DropCut|EqualPower|DjBlend|DjFilter):'
echo "ok   every style holds the +/−200 ms floor and the 3 s level"

# E-2: the cold-ending hold, rendered through the production gain curves. The
# chord has to be struck at unity and the incoming has to be under it, not a
# +3 dB bump.
cold="$(cargo test --lib mixer::tests::a_cold_ending -- --nocapture 2>&1)" || {
  echo "$cold" | tail -30
  exit 1
}
echo "$cold" | grep -E '^ColdEnd:'
echo "ok   a cold ending holds its chord at unity with the incoming underneath"

# G: the match is applied before the incoming's first audible frame, and a
# correlated DjBlend (same kicks, independent noise) keeps the 3 s gate.
match="$(cargo test --lib mixer::tests::a_transition_match_is_settled -- --nocapture 2>&1)" || {
  echo "$match" | tail -20
  exit 1
}
echo "ok   the transition match is settled before the first audible frame"
correlated="$(cargo test --lib mixer::tests::a_correlated_dj_blend -- --nocapture 2>&1)" || {
  echo "$correlated" | tail -25
  exit 1
}
echo "$correlated" | grep -E '^DjBlend correlated:'
echo "ok   a correlated DjBlend stays inside the 3 s level gate"

# C: the edge detector reads the recording's own level, not digital silence.
regions="$(cargo test --lib playback_regions::tests 2>&1)" || {
  echo "$regions" | tail -20
  exit 1
}
echo "ok   edge detection trims a relative fade tail and keeps quiet music"

# The scorecard reads both graphs from native-core/fixtures/models by default.
# Fill it with scripts/fetch-automix-models.sh; the test fails rather than
# silently measuring the DSP fallback when either graph is absent.
corpus="${AUTOMIX_CORPUS:-$HOME/Library/Caches/BitChord/audio}"
if [ ! -d "$corpus" ]; then
  echo "automix: plan-order checks passed; no corpus at $corpus"
  exit 0
fi

out="$(AUTOMIX_CORPUS="$corpus" RUST_LOG=native_core=info \
  cargo test --release --lib automix_corpus_scorecard -- --ignored --nocapture 2>&1)" || {
  echo "$out" | tail -20
  exit 1
}

echo "$out" | grep -E '^ *[0-9]+\. |^automix scorecard'
summary="$(echo "$out" | grep '^automix scorecard: usable' | tail -1)"
if [ -z "$summary" ]; then
  echo "automix: the scorecard printed no summary"
  exit 1
fi
median="$(echo "$summary" | sed -E 's/.*median fade ([0-9.]+)s.*/\1/')"
effects="$(echo "$summary" | sed -E 's/.*effects ([0-9]+)\/([0-9]+).*/\1/')"
pairs="$(echo "$summary" | sed -E 's/.*effects ([0-9]+)\/([0-9]+).*/\2/')"
minfade="$(echo "$summary" | sed -E 's/.*min fade ([0-9.]+)s.*/\1/')"
min_nondropcut="$(echo "$summary" | sed -E 's/.*min non-DropCut fade ([0-9.]+)s.*/\1/')"
bridged="$(echo "$summary" | sed -E 's/.*bridged ([0-9]+)\/([0-9]+).*/\1/')"

fail=0
# Enforced: freshness. At most three transitions in four use an effect (the
# owner's pacing, 2026-10-25); the corpus is paced as the app paces it.
if [ "$pairs" -gt 0 ]; then
  if [ $((effects * 100)) -le $((pairs * 75)) ]; then
    echo "ok   effects are within the 75% budget — $effects of $pairs"
  else
    echo "FAIL effects are $effects of $pairs, over the 75% budget"
    fail=1
  fi
fi

# Enforced: E. A final chord is never faded through on a handover that lands on
# the record's ending, and no mix-out discards more than the 12 s cap.
edges_line="$(echo "$out" | grep '^automix edges:' | tail -1)"
if [ -z "$edges_line" ]; then
  echo "FAIL the scorecard printed no edge line"
  fail=1
else
  clipped="$(echo "$edges_line" | sed -E 's/.*clipped final chords ([0-9]+).*/\1/')"
  max_out="$(echo "$edges_line" | sed -E 's/.*discarded out median [0-9.]+s max ([0-9.]+)s.*/\1/')"
  max_in="$(echo "$edges_line" | sed -E 's/.*in median [0-9.]+s max ([0-9.]+)s.*/\1/')"
  if [ "$clipped" = "0" ]; then
    echo "ok   no final chord is faded through — $edges_line"
  else
    echo "FAIL $clipped final chord(s) are clipped"
    fail=1
  fi
  awk -v m="$max_out" 'BEGIN { if (m + 0 <= 12.0) print "ok   outgoing discarded music stays within 12s — " m "s"; else { print "FAIL outgoing discarded music " m "s is over 12s"; exit 1 } }' || fail=1
  awk -v m="$max_in" 'BEGIN { if (m + 0 <= 12.0) print "ok   incoming discarded music stays within 12s — " m "s"; else { print "FAIL incoming discarded music " m "s is over 12s"; exit 1 } }' || fail=1
  echo "$edges_line" | sed -E 's/^automix edges: /     /'
fi

# Reported: length. These are the owner's bar and are met by the transition
# length work (E), not by this rule set, so they are printed, not enforced yet.
awk -v m="$median" 'BEGIN { if (m + 0 >= 8.0) print "ok   median overlap " m "s is at least a phrase pair (>= 8s)"; else print "target median overlap " m "s is under 8s" }'
awk -v m="$minfade" 'BEGIN { if (m + 0 >= 4.0) print "ok   shortest overlap " m "s is at least 4s (DropCut exempt)"; else print "target shortest overlap " m "s is under 4s" }'

# Enforced (E-2): the owner rejected short overlaps. Every non-DropCut blend is
# at least a 3 s phrase now that a cold ending keeps its phrase instead of
# collapsing to the chord's decay.
awk -v m="$min_nondropcut" 'BEGIN { if (m + 0 >= 3.0) print "ok   shortest non-DropCut overlap " m "s is at least 3s"; else { print "FAIL shortest non-DropCut overlap " m "s is under 3s"; exit 1 } }' || fail=1

# Reported: F. A bridge is an extension of a clean crossfade, so it is not a
# gate of its own; the per-row reason says why a pair did not bridge and the
# median line says whether the length work reached the owner's bar.
echo "     loop bridges: ${bridged:-0} of $pairs (the per-row reason names the blocker)"

exit "$fail"
