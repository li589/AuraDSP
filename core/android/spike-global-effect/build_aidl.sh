#!/bin/bash
# build_aidl.sh - build AIDL-native spike effect library (libspikeeq.so)
# Target: aarch64 Android 14+ (API 34), 16KB page alignment
set -e

SPK="$(cd "$(dirname "$0")" && pwd -W)"
NDK_BIN="D:/myPrograms/AndroidDevelop/Android-SDK/ndk/30.0.14904198/toolchains/llvm/prebuilt/windows-x86_64/bin"
CXX="$NDK_BIN/clang++.exe"
TARGET="--target=aarch64-linux-android34 --sysroot=D:/myPrograms/AndroidDevelop/Android-SDK/ndk/30.0.14904198/toolchains/llvm/prebuilt/windows-x86_64/sysroot"
NM="$NDK_BIN/llvm-nm.exe"

# mixed paths (forward slashes) are safe for both bash and clang
INC_SPIKE="$(cygpath -m "$SPK")/src/aidl"
INC_STUB="$(cygpath -m "$SPK")/third-party/include"
INC_FMQ="$(cygpath -m "$SPK")/aidl-src/libfmq/include"
INC_FMQ_BASE="$(cygpath -m "$SPK")/aidl-src/libfmq/base"
INC_GEN="$(cygpath -m "$SPK")/gen/include"
FNK="$(cygpath -m "$SPK")/aidl-src/frameworks_native/libs/binder/ndk"
GEN_SRC="$SPK/gen/gen-src"
FMQ="$SPK/aidl-src/libfmq"

CXXFLAGS="$TARGET -std=c++20 -O2 -fPIC -fvisibility=hidden -frtti -fexceptions \
  -I$INC_SPIKE \
  -I$INC_STUB \
  -I$INC_FMQ \
  -I$INC_FMQ_BASE \
  -I$FNK/include_cpp \
  -I$FNK/include_ndk \
  -I$FNK/include_platform \
  -I$INC_GEN"

OUT_DIR="$SPK/out"
mkdir -p "$OUT_DIR/obj"

# 1. Compile all generated AIDL NDK stubs (parallel, 8 jobs)
echo "=== [1/3] compiling generated stubs ($(find "$GEN_SRC" -name '*.cpp' | wc -l) files) ==="
find "$GEN_SRC" -name '*.cpp' -print0 | xargs -0 -P 8 -I{} bash -c \
  'set -e; in="{}"; b=$(cygpath -m "${in#'"$GEN_SRC"'/}" | tr "/" "_"); out="'"$OUT_DIR"'/obj/${b}.o";
   [ -f "$out" ] || "'"$CXX"'" '"$CXXFLAGS"' -c "$(cygpath -w "$in")" -o "$(cygpath -w "$out")"' || true

N_OBJ=$(ls "$OUT_DIR/obj" 2>/dev/null | wc -l)
echo "  objects after stage1: $N_OBJ"
if [ "$N_OBJ" -lt 130 ]; then
  echo "  !! some stubs failed, retrying serially for missing ones:"
  find "$GEN_SRC" -name '*.cpp' | while read -r in; do
    b=$(cygpath -m "${in#$GEN_SRC/}" | tr "/" "_"); out="$OUT_DIR/obj/${b}.o"
    if [ ! -f "$out" ]; then
      echo "    retry: $b"
      "$CXX" $CXXFLAGS -c "$(cygpath -w "$in")" -o "$(cygpath -w "$out")"
    fi
  done
fi

# 2. Compile libfmq + spike sources
echo "=== [2/3] compiling libfmq + spike ==="
for f in "$FMQ/EventFlag.cpp" "$FMQ/FmqInternal.cpp" \
         "$SPK/third-party/stub_impl.cpp" \
         "$SPK/src/aidl/SpikeEffect.cpp" "$SPK/src/aidl/SpikeExports.cpp"; do
  echo "  -- $(basename $f)"
  "$CXX" $CXXFLAGS -c "$(cygpath -w "$f")" -o "$OUT_DIR/obj/$(basename $f .cpp).o"
done

# 3. Link
echo "=== [3/3] linking libspikeeq.so ==="
"$CXX" $TARGET $CXXFLAGS -shared \
  -Wl,-z,max-page-size=16384 \
  -static-libstdc++ \
  -Wl,--version-script="$(cygpath -m "$SPK")/version_script.txt" \
  -o "$OUT_DIR/libspikeeq.so" \
  "$OUT_DIR/obj"/*.o \
  -lbinder_ndk -llog

echo "=== symbols check ==="
"$NM" -D --defined-only "$OUT_DIR/libspikeeq.so" | grep -E " T (createEffect|queryEffect|destroyEffect)$"
echo "=== BUILD OK: $OUT_DIR/libspikeeq.so ==="
ls -la "$OUT_DIR/libspikeeq.so"
