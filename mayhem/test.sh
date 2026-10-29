#!/usr/bin/env bash
#
# mayhem/test.sh — RUN ISA-L's own test executables (built by mayhem/build.sh) plus known-answer probes.
# exit 0 = pass. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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


TEST_DIR="$SRC/mayhem/build-test"
[ -d "$TEST_DIR" ] || { echo "missing $TEST_DIR (build.sh should have produced it)" >&2; exit 2; }

passed=0; failed=0
ok()   { passed=$((passed + 1)); echo "PASS $1"; }
fail() { failed=$((failed + 1)); echo "FAIL $1" >&2; }

# 1) Upstream's own test executables. ctest only enumerates them; each binary is run directly and its
#    own result line is asserted (a no-op binary prints nothing, so it cannot satisfy this).
tests=$(cd "$TEST_DIR" && ctest -N | sed -n 's/^ *Test *#[0-9]*: //p')
[ -n "$tests" ] || { echo "ctest lists no tests" >&2; exit 2; }
for t in $tests; do
  if [ ! -x "$TEST_DIR/$t" ]; then fail "$t (binary missing)"; continue; fi
  out=$(cd "$TEST_DIR" && timeout 600 "./$t" 2>&1); rc=$?
  last=$(printf '%s\n' "$out" | tail -n 1)
  if [ "$t" = version_test ]; then pat='^Tool version: [0-9]+\.[0-9]+\.[0-9]+'; else pat='(Pass|All tests passed)'; fi
  if [ $rc -eq 0 ] && printf '%s' "$last" | grep -Eq "$pat"; then ok "$t"; else fail "$t (rc=$rc, last line: $last)"; fi
done

# 2) Known-answer probe: exact values from published check vectors / fixed streams.
kat=$("$SRC/isal_kat" 2>&1) || true
expect='crc32_gzip_refl=cbf43926
crc16_t10dif=d0db
crc64_ecma_refl=995dc9bbdf1939fa
adler32=11e60398
gf_mul=06,1d
inflate=0,hello world
roundtrip_l0=0,0,same,small
roundtrip_l1=0,0,same,small
roundtrip_l2=0,0,same,small
roundtrip_l3=0,0,same,small'
if [ "$kat" = "$expect" ]; then ok "isal_kat known answers"; else fail "isal_kat known answers: got: $kat"; fi

# 3) igzip CLI against the system gzip: each tool must read the other's output back exactly.
igzip="$TEST_DIR/programs/igzip"
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
for i in $(seq 1 500); do echo "isa-l line $i: the quick brown fox jumps over the lazy dog"; done > "$work/in.txt"
want=$(sha256sum < "$work/in.txt")
(cd "$work" && "$igzip" -c in.txt > in.txt.gz)
got=$(gzip -dc "$work/in.txt.gz" 2>/dev/null | sha256sum)
if [ -s "$work/in.txt.gz" ] && [ "$got" = "$want" ]; then ok "igzip output decodes with gzip"; else fail "igzip output decodes with gzip"; fi
gzip -c "$work/in.txt" > "$work/gz.gz"
got=$(cd "$work" && "$igzip" -dc gz.gz 2>/dev/null | sha256sum)
if [ "$got" = "$want" ]; then ok "igzip decodes gzip output"; else fail "igzip decodes gzip output"; fi

emit_ctrf "isal-tests" "$passed" "$failed" 0
