# bridge/ — 常驻 FFI 桥（无编号）

> 02/03/04 是传输/宿主实现；桥只是"把某传输接到引擎"的薄 FFI 适配层，
> 不单列编号（原 `05_vm_bridge/` 已并入 `vm_bridge/`），避免
> "有的单出编号、有的集成在宿主目录"的混乱。

## 布局

```text
bridge/
  README.md          # 本文件（规约）
  vm_bridge/         # Voicemeeter 回调桥 → auravm_bridge.dll（Dart: audio_vbridge.dart）
    VmBridge.{h,cpp,def}
  asio_bridge/       # ASIO 常驻桥 → auraasio_bridge.dll（Dart: audio_abridge.dart）
    AsioBridge.{h,cpp,def}   # 宿主仍在 ../04_asio_client（AsioHost.*），桥只含 FFI 适配
```

## 规约

1. **桥不实现传输**：VM 回调泵走 `../02_voicemeeter_client/VmPumpCore.h`，
   ASIO 传输走 `../04_asio_client/AsioHost.h`；桥内只做句柄管理/参数镜像/重建。
2. **契约对齐**：新增桥必须镜像 `vm_bridge/VmBridge.h` 的
   detect/start/stop/status/set_param(+_str)/get_param(+_str)/viz_read/bypass/test
   件套（ASIO 仅多 buf_size/out_pair 两个宿主参数），Dart 侧同构绑定。
   ASIO 重建一律走 Dart 侧 stop+start（isolate 回放镜像），桥内不设镜像。
3. **RT 铁律**：回调内零锁零分配；引擎建/销只在控制线程（CHANGE/ASIO reset
   一律走"停→销→启→重建→回放镜像"序列，见 `VmBridge.cpp MonitorProc`）。
4. **参数镜像**：凡经桥下发的参数（含字符串）必须同时记镜像，重建后回放；
   回归必须有"重建后回读仍一致"的 smoke 断言（`smoke_vm_bridge.py`
   `SURVIVED REBUILD` 件套为范本）。
5. **CMake**：在父级 `CMakeLists.txt` 用 `BRIDGEDIR` 变量统一起名
   （`VMBRIDGE`/`ASIOBRIDGE`），不要散写相对路径。
