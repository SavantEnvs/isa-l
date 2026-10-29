#!/usr/bin/env bash
#
# mayhem/build.sh — build ISA-L's libFuzzer harnesses (sanitized) and its own test suite (normal flags).
# Runs inside the commit image as `mayhem` in /mayhem; safe to re-run offline.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
OUT=/mayhem
FUZZ_DIR="$SRC/mayhem/build-fuzz"
TEST_DIR="$SRC/mayhem/build-test"

# 1) Sanitized + coverage-instrumented static libisal (project code, not just the harness).
#    fuzzer-no-link adds SanCov to the library so the fuzzed code reports edges.
LIB_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1"
cmake -S "$SRC" -B "$FUZZ_DIR" -G Ninja \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_BUILD_TYPE=None \
    -DCMAKE_C_FLAGS="$LIB_FLAGS" \
    -DBUILD_SHARED_LIBS=OFF -DISAL_BUILD_TESTS=OFF -DISAL_BUILD_PERF_TESTS=OFF \
    -DISAL_BUILD_ISAL_SHIM=OFF -DISAL_BUILD_FUZZ_TESTS=OFF
cmake --build "$FUZZ_DIR" -j"$MAYHEM_JOBS" --target isal
LIBISAL="$FUZZ_DIR/libisal.a"
[ -f "$LIBISAL" ]

# 2) lsan hook (leaks are not the bug class we fuzz for).
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$FUZZ_DIR/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_DIR/standalone_main.o"

# The shim harness is meant to exercise ISA-L's zlib-compatible shim, so link the shim sources
# (they define deflate*/inflate*/compress2/uncompress2) ahead of -lz; the other harnesses never use it.
SHIM_OBJS=()
for f in shim_deflate shim_inflate; do
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1 -I"$SRC/include" \
        -c "$SRC/igzip/shim/$f.c" -o "$FUZZ_DIR/$f.o"
    SHIM_OBJS+=("$FUZZ_DIR/$f.o")
done

build_harness() {  # <fuzzer-name> <source> [extra objs/libs...]
    local name="$1" srcfile="$2"; shift 2
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 $LIB_FUZZING_ENGINE -I"$SRC/include" \
        "$srcfile" "$FUZZ_DIR/lsan_off.o" "$@" "$LIBISAL" -o "$OUT/$name"
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -I"$SRC/include" \
        "$srcfile" "$FUZZ_DIR/standalone_main.o" "$FUZZ_DIR/lsan_off.o" "$@" "$LIBISAL" -o "$OUT/$name-standalone"
}

F="$SRC/tests/fuzz"
build_harness isal_fuzz_crc                  "$F/crc_fuzz_test.c"
build_harness isal_fuzz_ec                   "$F/ec_fuzz_test.c"
build_harness isal_fuzz_raid                 "$F/raid_fuzz_test.c"
build_harness isal_fuzz_igzip_round_trip     "$F/igzip_simple_round_trip_fuzz_test.c"
build_harness isal_fuzz_igzip_simple_inflate "$F/igzip_simple_inflate_fuzz_test.c"
build_harness isal_fuzz_igzip_checked_inflate "$F/igzip_checked_inflate_fuzz_test.c" -lz
build_harness isal_fuzz_igzip                "$F/igzip_fuzz_test.c"
build_harness isal_fuzz_shim                 "$F/shim_fuzz_test.c" "${SHIM_OBJS[@]}" -lz

# 3) The project's own test suite + igzip CLI, with NORMAL flags (no sanitizers, no -gdwarf-3).
cmake -S "$SRC" -B "$TEST_DIR" -G Ninja \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS" \
    -DBUILD_SHARED_LIBS=OFF -DISAL_BUILD_TESTS=ON -DISAL_BUILD_PERF_TESTS=OFF \
    -DISAL_BUILD_ISAL_SHIM=OFF -DISAL_BUILD_IGZIP_CLI=ON -DISAL_BUILD_FUZZ_TESTS=OFF
cmake --build "$TEST_DIR" -j"$MAYHEM_JOBS"

# Known-answer probe: dynamically linked, never sanitized.
$CC -O1 -I"$SRC/include" "$SRC/mayhem/kat/isal_kat.c" "$TEST_DIR/libisal.a" -o "$OUT/isal_kat"
