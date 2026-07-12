#!/usr/bin/env bash
#
# mayhem/test.sh — AUTHORED behavioral oracle for Precomp (upstream ships NO test suite;
# tests_found=0). Precomp's contract is a LOSSLESS round trip: `precomp <f>` produces a .pcf
# container and `precomp -r <f>.pcf` must reconstruct the ORIGINAL file byte-for-byte. This oracle
# asserts that reconstruction equals the input (a golden identity), so a PATCH that "fixes" a bug
# by making the program exit(0) / no-op FAILS here (the restored file would be missing or wrong).
# It exercises the real recompression logic by feeding a genuine DEFLATE (gzip) stream, plus a
# store-only case. build.sh already compiled the CLI to build-tests/precomp; this only RUNS it.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

PRECOMP="$SRC/build-tests/precomp"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$PRECOMP" ]; then
  echo "test.sh: $PRECOMP missing — build.sh did not produce the oracle CLI" >&2
  emit_ctrf "precomp-roundtrip" 0 1
  exit 1
fi

passed=0; failed=0

# roundtrip <name> : $work/orig has been created by the caller; assert precomp restores it exactly.
roundtrip() {
  local name="$1" work="$2"
  ( cd "$work"
    # exit 2 = RETURN_NOTHING_DECOMPRESSED: a valid .pcf was still written (store path)
    "$PRECOMP" -ocomp.pcf orig            >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]     || exit 20
    [ -s comp.pcf ]                        || exit 21   # a container was actually produced
    "$PRECOMP" -r -orestored comp.pcf      >/dev/null 2>&1 || exit 22
    cmp -s orig restored )                 # <-- the behavioral assertion: lossless identity
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "PASS $name (lossless round trip)"; passed=$((passed+1))
  else
    echo "FAIL $name (rc=$rc: restored file differs from original or step failed)"; failed=$((failed+1))
  fi
}

# 1) DEFLATE stream — drives the real gzip recompression path (precomp must reproduce the exact
#    deflate bytes; a broken recompressor yields a non-identical restore).
w1="$(mktemp -d)"; seq 1 20000 > "$w1/plain"; gzip -n -c "$w1/plain" > "$w1/orig"; rm -f "$w1/plain"
roundtrip "gzip-deflate-roundtrip" "$w1"

# 2) Incompressible bytes — the store/passthrough path.
w2="$(mktemp -d)"; head -c 30000 /dev/urandom > "$w2/orig"
roundtrip "raw-store-roundtrip" "$w2"

emit_ctrf "precomp-roundtrip" "$passed" "$failed"
