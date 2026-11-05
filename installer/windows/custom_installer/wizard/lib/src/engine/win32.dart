/// Win32 系统集成层（设计 §5）：注册表、电量提权检查、ShellExecute、
/// ASIO 驱动 DLL 的 DllRegisterServer FFI、进程守卫（tasklist/taskkill）。
///
/// 注册表/令牌/ShellExecute 用 package:win32 的生成绑定（已按其
/// 5.15 源码核对签名）；其余走 dart:ffi 直调，避免未核实 API。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

const int kHkeyCurrentUser = 0x80000001;
const int kHkeyLocalMachine = 0x80000002;
const int _regSz = 1;
const int _regDword = 4;
const int _keyWrite = 0x20006;
const int _tokenQuery = 0x0008;
const int _tokenElevation = 20;

/// 当前进程是否已提权（管理员）。
bool isElevated() {
  final token = calloc<IntPtr>();
  final elevation = calloc<Uint32>();
  final len = calloc<Uint32>();
  try {
    if (OpenProcessToken(GetCurrentProcess(), _tokenQuery, token) == 0) {
      return false;
    }
    final ok = GetTokenInformation(
        token.value, _tokenElevation, elevation, 4, len);
    return ok != 0 && elevation.value != 0;
  } finally {
    calloc.free(token);
    calloc.free(elevation);
    calloc.free(len);
  }
}

/// 删除某键下的一个值（键不存在/值不存在视为成功）。
bool registryDeleteValue(int hive, String subKey, String valueName) {
  final keyPtr = calloc<IntPtr>();
  final sub = subKey.toNativeUtf16();
  final name = valueName.toNativeUtf16();
  const keySetValue = 0x0002;
  try {
    final rc = RegOpenKeyEx(hive, sub, 0, keySetValue, keyPtr);
    if (rc == 2) return true; // ERROR_FILE_NOT_FOUND
    if (rc != 0) return false;
    final drc = RegDeleteValue(keyPtr.value, name);
    RegCloseKey(keyPtr.value);
    return drc == 0 || drc == 2;
  } finally {
    calloc.free(keyPtr);
    calloc.free(sub);
    calloc.free(name);
  }
}

/// 在 hive 下创建/打开键并写入一组值（字符串与 DWORD 混合）。
/// 返回是否全部成功。
bool registryWriteValues(
  int hive,
  String subKey,
  Map<String, Object> values,
) {
  final keyPtr = calloc<IntPtr>();
  final sub = subKey.toNativeUtf16();
  try {
    final rc = RegCreateKeyEx(hive, sub, 0, nullptr, 0, _keyWrite, nullptr,
        keyPtr, nullptr);
    if (rc != 0) return false;
    final hKey = keyPtr.value;
    var ok = true;
    values.forEach((name, value) {
      final namePtr = name.toNativeUtf16();
      try {
        if (value is String) {
          final data = value.toNativeUtf16();
          final rc2 = RegSetValueEx(hKey, namePtr, 0, _regSz,
              data.cast<Uint8>(), (value.length + 1) * 2);
          calloc.free(data);
          ok = ok && rc2 == 0;
        } else if (value is int) {
          final data = calloc<Uint32>()..value = value;
          final rc2 = RegSetValueEx(
              hKey, namePtr, 0, _regDword, data.cast<Uint8>(), 4);
          calloc.free(data);
          ok = ok && rc2 == 0;
        }
      } finally {
        calloc.free(namePtr);
      }
    });
    RegCloseKey(hKey);
    return ok;
  } finally {
    calloc.free(keyPtr);
    calloc.free(sub);
  }
}

/// 删除整棵注册表子树（不存在视为成功）。
bool registryDeleteTree(int hive, String subKey) {
  final sub = subKey.toNativeUtf16();
  try {
    final rc = RegDeleteTree(hive, sub);
    return rc == 0 || rc == 2; // ERROR_FILE_NOT_FOUND
  } finally {
    calloc.free(sub);
  }
}

/// 以管理员身份重启指定 exe（ShellExecute runas）。返回是否已发起。
bool relaunchElevated(String exe, String parameters) {
  final op = 'runas'.toNativeUtf16();
  final file = exe.toNativeUtf16();
  final params = parameters.toNativeUtf16();
  try {
    final rc = ShellExecute(0, op, file, params, nullptr, 1 /* SW_SHOWNORMAL */);
    return rc > 32;
  } finally {
    calloc.free(op);
    calloc.free(file);
    calloc.free(params);
  }
}

typedef _DllRegNative = Int32 Function();
typedef _DllRegDart = int Function();

/// 调用某 DLL 的 DllRegisterServer / DllUnregisterServer（ASIO 注册）。
/// 返回 HRESULT（0 = S_OK）。
int callDllRegisterServer(String dllPath, {required bool register}) {
  final lib = DynamicLibrary.open(dllPath);
  final fn = lib.lookupFunction<_DllRegNative, _DllRegDart>(
      register ? 'DllRegisterServer' : 'DllUnregisterServer');
  return fn();
}

const kGuardedImages = ['auradsp_app.exe', 'plugin_host_x64.exe', 'plugin_host_x86.exe'];

/// 枚举受守卫进程的 PID（tasklist CSV 解析，与系统语言无关）。
Future<List<int>> guardedPids() async {
  final pids = <int>[];
  for (final image in kGuardedImages) {
    final r = await Process.run(
        'tasklist', ['/FI', 'IMAGENAME eq $image', '/FO', 'CSV', '/NH']);
    if (r.exitCode != 0) continue;
    for (final line in (r.stdout as String).split('\n')) {
      final m = RegExp(r'^"[^"]+","(\d+)"').firstMatch(line.trim());
      if (m != null) pids.add(int.parse(m.group(1)!));
    }
  }
  return pids;
}

/// 优雅关闭（taskkill 无 /F 发送关闭信号）→ 等待 → 强制结束。
Future<void> closeGuardedProcesses() async {
  final pids = await guardedPids();
  for (final pid in pids) {
    await Process.run('taskkill', ['/PID', '$pid']);
  }
  if (pids.isEmpty) return;
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if ((await guardedPids()).isEmpty) return;
  }
  for (final pid in await guardedPids()) {
    await Process.run('taskkill', ['/F', '/PID', '$pid']);
  }
}
