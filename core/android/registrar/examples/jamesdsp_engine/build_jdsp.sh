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

HERE_W="$(cd "$(dirname "$0")" && pwd -W 2>/dev/null || true)"
# CP-13（2026-11-01）：macOS/Linux 无 cygpath/pwd -W 时提供直通实现，
# 使脚本内既有的 $(cygpath -m/-w/-u ...) 调用无需逐处改写。
if [ -z "$HERE_W" ] || ! command -v cygpath >/dev/null 2>&1; then
    cygpath() { case "${1:-}" in -w|-m|-u) shift ;; esac; printf '%s' "${1:-}"; }
    export -f cygpath
    HERE_W="$(cd "$(dirname "$0")" && pwd)"
fi
REG_W="$(cd "$HERE_W/../.." && pwd -W 2>/dev/null || true)"
[ -n "$REG_W" ] || REG_W="$(cd "$HERE_W/../.." && pwd)"
CORE_W="$(cd "$REG_W/.." && pwd -W 2>/dev/null || true)"
[ -n "$CORE_W" ] || CORE_W="$(cd "$REG_W/.." && pwd)"

# NDK：优先 ANDROID_NDK / ANDROID_NDK_HOME；缺省回退历史 Windows 路径。
NDK_ROOT="${ANDROID_NDK:-${ANDROID_NDK_HOME:-${NDK_ROOT:-D:/myPrograms/AndroidDevelop/Android-SDK/ndk/30.0.14904198}}}"
case "$(uname -s)" in
    Darwin) NDK_HOST_TAG=darwin-x86_64 ;;
    Linux)  NDK_HOST_TAG=linux-x86_64 ;;
    *)      NDK_HOST_TAG=windows-x86_64 ;;
esac
NDK_BIN="$NDK_ROOT/toolchains/llvm/prebuilt/$NDK_HOST_TAG/bin"
SYSROOT="$NDK_ROOT/toolchains/llvm/prebuilt/$NDK_HOST_TAG/sysroot"
CC="$NDK_BIN/clang"
CXX="$NDK_BIN/clang++"
NM="$NDK_BIN/llvm-nm"
if [ "$NDK_HOST_TAG" = "windows-x86_64" ]; then
    CC="$CC.exe"
    CXX="$CXX.exe"
    NM="$NM.exe"
fi

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
  if [ ! -f "$out" ] || [ "$in" -nt "$out" ]; then
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
  if [ ! -f "$out" ] || [ "$f" -nt "$out" ]; then
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
