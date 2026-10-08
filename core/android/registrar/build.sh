#!/bin/bash
# build.sh — build registrar-core-based effect library (libspikeeq.so)
#
# Source layout (all source-integrated, no prebuilt packages):
#   ../aidl-gen/     AIDL NDK generated stubs (rebuildable from vendor-src .aidl)
#   ../vendor-src/   third-party sources: libfmq, binder-ndk headers, system_media, hw interfaces
#   ../stubs/        platform shims (cutils/libbase/libutils replacements)
set -e

REG_W="$(cd "$(dirname "$0")" && pwd -W)"          # windows path (D:/...)
CORE_W="$(cd "$REG_W/.." && pwd -W)"
REG="$(cygpath -u "$REG_W")"
CORE="$(cygpath -u "$CORE_W")"

NDK_BIN="D:/myPrograms/AndroidDevelop/Android-SDK/ndk/30.0.14904198/toolchains/llvm/prebuilt/windows-x86_64/bin"
CXX="$NDK_BIN/clang++.exe"
TARGET="--target=aarch64-linux-android34 --sysroot=D:/myPrograms/AndroidDevelop/Android-SDK/ndk/30.0.14904198/toolchains/llvm/prebuilt/windows-x86_64/sysroot"
NM="$NDK_BIN/llvm-nm.exe"

INC_REG="D:$(echo "$REG_W" | cut -c3-)"   # unused placeholder; kept simple below

CXXFLAGS="--target=aarch64-linux-android34 --sysroot=D:/myPrograms/AndroidDevelop/Android-SDK/ndk/30.0.14904198/toolchains/llvm/prebuilt/windows-x86_64/sysroot -std=c++20 -O2 -fPIC -fvisibility=hidden -frtti -fexceptions \
  -I$(cygpath -m "$REG_W")/include \
  -I$(cygpath -m "$REG_W")/examples/spike_eq \
  -I$(cygpath -m "$CORE_W")/stubs/include \
  -I$(cygpath -m "$CORE_W")/vendor-src/libfmq/include \
  -I$(cygpath -m "$CORE_W")/vendor-src/libfmq/base \
  -I$(cygpath -m "$CORE_W")/vendor-src/frameworks_native/binder-ndk/include_cpp \
  -I$(cygpath -m "$CORE_W")/vendor-src/frameworks_native/binder-ndk/include_ndk \
  -I$(cygpath -m "$CORE_W")/vendor-src/frameworks_native/binder-ndk/include_platform \
  -I$(cygpath -m "$CORE_W")/aidl-gen/include"

OUT_DIR="$REG_W/out"
mkdir -p "$OUT_DIR/obj"

GEN_SRC_P="$CORE/aidl-gen/gen-src"

echo "=== [1/3] compiling AIDL generated stubs ($(find "$GEN_SRC_P" -name '*.cpp' | wc -l) files) ==="
find "$GEN_SRC_P" -name '*.cpp' -print0 | xargs -0 -P 8 -I{} bash -c '
  set -e
  in="{}"
  rel="${in#'"$GEN_SRC_P"'/}"
  b=$(echo "$rel" | tr "/" "_")
  out="'"$OUT_DIR"'/obj/${b}.o"
  [ -f "$out" ] || "'"$CXX"'" '"$CXXFLAGS"' -c "$(cygpath -w "$in")" -o "$(cygpath -w "$out")"' || true

N_OBJ=$(ls "$OUT_DIR/obj" 2>/dev/null | wc -l)
echo "  objects after stage1: $N_OBJ"
if [ "$N_OBJ" -lt 130 ]; then
  find "$GEN_SRC_P" -name '*.cpp' | while read -r in; do
    rel="${in#$GEN_SRC_P/}"
    b=$(echo "$rel" | tr "/" "_")
    out="$OUT_DIR/obj/${b}.o"
    if [ ! -f "$out" ]; then
      echo "    retry: $b"
      "$CXX" $CXXFLAGS -c "$(cygpath -w "$in")" -o "$(cygpath -w "$out")"
    fi
  done
fi

echo "=== [2/3] compiling libfmq + shims + registrar core + example ==="
for f in "$CORE/vendor-src/libfmq/EventFlag.cpp" \
         "$CORE/vendor-src/libfmq/FmqInternal.cpp" \
         "$CORE/stubs/stub_impl.cpp" \
         "$REG/src/AidlEffectBase.cpp" \
         "$REG/src/Exports.cpp" \
         "$REG/examples/spike_eq/SpikeEqEngine.cpp" \
         "$REG/examples/spike_eq/main.cpp"; do
  echo "  -- $(basename $f)"
  "$CXX" $CXXFLAGS -c "$(cygpath -w "$f")" -o "$OUT_DIR/obj/core_$(basename $f .cpp).o"
done

echo "=== [3/3] linking libspikeeq.so ==="
"$CXX" $CXXFLAGS -shared \
  -Wl,-z,max-page-size=16384 \
  -static-libstdc++ \
  -Wl,--version-script="$(cygpath -m "$REG_W")/version_script.txt" \
  -o "$OUT_DIR/libspikeeq.so" \
  "$OUT_DIR/obj"/*.o \
  -lbinder_ndk -llog

echo "=== symbols check ==="
"$NM" -D --defined-only "$(cygpath -w "$OUT_DIR/libspikeeq.so")"
echo "=== BUILD OK: $OUT_DIR/libspikeeq.so ==="
ls -la "$OUT_DIR/libspikeeq.so"
