#!/bin/bash
# build_jdsp.sh — build libjdsp.so (full JamesDSP engine on registrar core)
#
# Sources (all from source/, per docs/项目架构与开发规范.md §3):
#   CORE/vendor-src/libjamesdsp/   JamesDSP C engine (83 files, no prebuilt)
#   CORE/aidl-gen/                 AIDL NDK stubs (shared, pre-generated)
#   CORE/vendor-src/(libfmq...)    platform sources (shared)
#   CORE/stubs/                    platform shims (shared)
#
# Output: out/libjdsp.so (same 3-symbol HAL dlsym contract as libspikeeq.so)
set -e

HERE_W="$(cd "$(dirname "$0")" && pwd -W)"         # examples/jamesdsp_engine
REG_W="$(cd "$HERE_W/../.." && pwd -W)"            # registrar/
CORE_W="$(cd "$REG_W/.." && pwd -W)"               # core/android/

NDK_BIN="D:/myPrograms/AndroidDevelop/Android-SDK/ndk/30.0.14904198/toolchains/llvm/prebuilt/windows-x86_64/bin"
SYSROOT="D:/myPrograms/AndroidDevelop/Android-SDK/ndk/30.0.14904198/toolchains/llvm/prebuilt/windows-x86_64/sysroot"
CC="$NDK_BIN/clang.exe"
CXX="$NDK_BIN/clang++.exe"
NM="$NDK_BIN/llvm-nm.exe"

OUT_DIR="$HERE_W/out"
mkdir -p "$OUT_DIR/obj_c" "$OUT_DIR/obj_cpp"

M=$(cygpath -m "$CORE_W/vendor-src/libjamesdsp")

CFLAGS="--target=aarch64-linux-android34 --sysroot=$SYSROOT \
  -std=gnu11 -O2 -fPIC -fvisibility=hidden -ffunction-sections -fdata-sections \
  -Wno-incompatible-function-pointer-types -Wno-incompatible-pointer-types \
  -Wno-visibility -Wno-enum-conversion -Wno-implicit-int -Wno-implicit-function-declaration \
  -I$M \
  -I$M/jdsp"

CXXFLAGS="--target=aarch64-linux-android34 --sysroot=$SYSROOT -std=c++20 -O2 -fPIC -fvisibility=hidden -frtti -fexceptions \
  -I$(cygpath -m "$REG_W")/include \
  -I$(cygpath -m "$HERE_W") \
  -I$(cygpath -m "$CORE_W")/stubs/include \
  -I$(cygpath -m "$CORE_W")/vendor-src/libfmq/include \
  -I$(cygpath -m "$CORE_W")/vendor-src/libfmq/base \
  -I$(cygpath -m "$CORE_W")/vendor-src/frameworks_native/binder-ndk/include_cpp \
  -I$(cygpath -m "$CORE_W")/vendor-src/frameworks_native/binder-ndk/include_ndk \
  -I$(cygpath -m "$CORE_W")/vendor-src/frameworks_native/binder-ndk/include_platform \
  -I$(cygpath -m "$CORE_W")/aidl-gen/include \
  -I$M"

# --- collect C engine file list (no pipes: errors must abort the build) ---
C_LIST="$OUT_DIR/c_sources.txt"
find "$(cygpath -u "$CORE_W/vendor-src/libjamesdsp")" -name '*.c' ! -name 'cpthread.c' | sort > "$C_LIST"

echo "=== [1/4] compiling JamesDSP C engine ($(wc -l < "$C_LIST") files) ==="
while IFS= read -r in; do
  rel="${in#$(cygpath -u "$CORE_W/vendor-src/libjamesdsp/")}"
  b=$(echo "$rel" | tr "/" "_")
  out="$OUT_DIR/obj_c/${b%.c}.o"
  if [ ! -f "$out" ]; then
    "$CC" $CFLAGS -c "$(cygpath -w "$in")" -o "$(cygpath -w "$out")"
  fi
done < "$C_LIST"
echo "  objects: $(ls "$OUT_DIR/obj_c" | wc -l)"

# --- AIDL generated stubs ---
GEN_SRC="$(cygpath -u "$CORE_W/aidl-gen/gen-src")"
CPP_LIST="$OUT_DIR/cpp_sources.txt"
find "$GEN_SRC" -name '*.cpp' | sort > "$CPP_LIST"

echo "=== [2/4] compiling AIDL generated stubs ($(wc -l < "$CPP_LIST") files) ==="
while IFS= read -r in; do
  rel="${in#$GEN_SRC/}"
  b=$(echo "$rel" | tr "/" "_")
  out="$OUT_DIR/obj_cpp/${b%.cpp}.o"
  if [ ! -f "$out" ]; then
    "$CXX" $CXXFLAGS -c "$(cygpath -w "$in")" -o "$(cygpath -w "$out")"
  fi
done < "$CPP_LIST"
echo "  objects: $(find "$OUT_DIR/obj_cpp" -name '*.o' ! -name 'reg_*' | wc -l)"

echo "=== [3/4] compiling libfmq + shims + registrar core + engine ==="
for f in "$CORE_W/vendor-src/libfmq/EventFlag.cpp" \
         "$CORE_W/vendor-src/libfmq/FmqInternal.cpp" \
         "$CORE_W/stubs/stub_impl.cpp" \
         "$REG_W/src/AidlEffectBase.cpp" \
         "$REG_W/src/Exports.cpp" \
         "$HERE_W/JamesDspEngine.cpp" \
         "$HERE_W/main.cpp"; do
  b="$(basename $f .cpp)"
  out="$OUT_DIR/obj_cpp/reg_$b.o"
  if [ ! -f "$out" ]; then
    echo "  -- $b"
    "$CXX" $CXXFLAGS -c "$(cygpath -w "$f")" -o "$(cygpath -w "$out")"
  fi
done

echo "=== [4/4] linking libjdsp.so ==="
"$CXX" $CXXFLAGS -shared \
  -Wl,-z,max-page-size=16384 \
  -static-libstdc++ \
  -Wl,--gc-sections \
  -Wl,--version-script="$(cygpath -m "$REG_W")/version_script.txt" \
  -o "$OUT_DIR/libjdsp.so" \
  "$OUT_DIR/obj_c"/*.o "$OUT_DIR/obj_cpp"/*.o \
  -lbinder_ndk -llog

echo "=== symbols check ==="
"$NM" -D --defined-only "$(cygpath -w "$OUT_DIR/libjdsp.so")"
echo "=== BUILD OK: $OUT_DIR/libjdsp.so ==="
ls -la "$OUT_DIR/libjdsp.so"
