#!/usr/bin/env bash
#
# mayhem/build.sh — build Precomp's fuzz target + the behavioral-oracle CLI.
#
# Precomp has no upstream test suite, so mayhem/test.sh is an AUTHORED round-trip (KAT) oracle;
# this script builds both the sanitized fuzz target and a clean CLI for that oracle.
#
#  1. Sanitized project build (cmake) — instruments contrib/* AND precomp; also yields the object
#     files we relink into the fuzz target.
#  2. Fuzz target /mayhem/precomp — recompiles precomp.cpp as the PRECOMPDLL library (exposing
#     recompress_file) and links it with the sanitized contrib objects + mayhem/harness_precomp.cpp
#     (a file-input driver over the `precomp -r` reconstruction code path).
#  3. Clean CLI build-tests/precomp (project's NORMAL flags) — used only by mayhem/test.sh.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS

cd "$SRC"

# clang-19 rejects C99 implicit function declarations (-Werror by default); upstream's liblzma
# rangecoder headers call assert() without including <assert.h>. Force-include it into every C TU
# (a build-flag fix — no upstream edits).
CFIX="-include assert.h"

# Preprocessor defines + include dirs mirror CMakeLists.txt (add_definitions / include_directories)
# so the standalone precomp.cpp/harness compiles are ABI-identical to the cmake-built contrib objects.
DEFS="-DHAVE_BOOL -DBUILD_LIB -DBIT64"
INCLUDES="-I. \
  -Icontrib/liblzma -Icontrib/liblzma/api -Icontrib/liblzma/check -Icontrib/liblzma/common \
  -Icontrib/liblzma/delta -Icontrib/liblzma/lz -Icontrib/liblzma/lzma -Icontrib/liblzma/rangecoder \
  -Icontrib/liblzma/simple \
  -Icontrib/brunsli/c/common -Icontrib/brunsli/c/dec -Icontrib/brunsli/c/enc -Icontrib/brunsli/c/include \
  -Icontrib/brotli/c/include"

# ---- 1) sanitized project build (instruments the fuzzed code + carries DWARF < 4) -------------
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $CFIX" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
cmake --build build -j"$MAYHEM_JOBS"

# ---- 2) fuzz target: relink the sanitized contrib objects with the PRECOMPDLL library + harness ----
# All contrib/* objects from the cmake build EXCEPT precomp.cpp.o (that one is the CLI `main` build;
# we recompile precomp.cpp as the PRECOMPDLL library instead so recompress_file() is callable).
mapfile -t CONTRIB_OBJS < <(find build/CMakeFiles/precomp.dir -name '*.o' ! -name 'precomp.cpp.o')

# `-fdeclspec` lets clang accept upstream's __declspec(dllexport) on Linux (the DLL export macro).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++11 -fdeclspec -DPRECOMPDLL $DEFS $INCLUDES \
  -c precomp.cpp -o build/precomp_dll.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++11 -fdeclspec -DPRECOMPDLL $DEFS $INCLUDES \
  -c mayhem/harness_precomp.cpp -o build/harness_precomp.o
# The Switches ctor is a non-inline definition in precomp_dll.h, emitted by BOTH the library TU and
# the harness TU; allow the duplicate (identical) definition rather than editing the upstream header.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -Wl,--allow-multiple-definition \
  build/harness_precomp.o build/precomp_dll.o "${CONTRIB_OBJS[@]}" \
  -lpthread -o /mayhem/precomp

# ---- 3) clean CLI for the behavioral oracle (project's normal flags; NOT sanitized) -----------
cmake -S . -B build-tests -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$CFIX"
cmake --build build-tests -j"$MAYHEM_JOBS" --target precomp

echo "build.sh: done — fuzz target /mayhem/precomp; oracle CLI build-tests/precomp"
