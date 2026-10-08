# stubs — 平台替代层（Platform Shims）

效果库运行于 vendor 进程（`hal_audio_default`），该环境**没有** NDK/应用常见的
libcutils / libbase / libutils 可用（Oplus ROM 上连 ashmem/memfd 都被 SELinux 收紧）。
本目录提供这些库的**最小替代实现**，静态编入每个效果 .so：

| 文件/目录 | 替代的上游 | 说明 |
|---|---|---|
| `include/cutils/native_handle.h` + `stub_impl.cpp` | libcutils | native_handle_create/close/delete（隐藏可见性，零符号冲突） |
| `include/cutils/ashmem.h` + `stub_impl.cpp` | libcutils | 共享内存分配三级回退：memfd → /dev/ashmem → `/data/vendor/audio/.spike_fmq_*` 文件（Oplus SELinux 实测唯一可行路径） |
| `include/android-base/unique_fd.h` | libbase | RAII fd（含与 int 比较） |
| `include/android-base/logging.h` | libbase | `LOG(LEVEL)` 流式 + `CHECK(exp) << msg`（转 __android_log_print） |
| `include/utils/Log.h` | libutils | ALOGx 宏 |
| `include/utils/Errors.h` | libutils | status_t + 错误枚举（namespace android，字面量防溢出） |
| `include/utils/SystemClock.h` | libutils | elapsedRealtimeNano（CLOCK_BOOTTIME） |

规则：
- 所有符号 `-fvisibility=hidden`，version script 只导出三个 extern "C" HAL 契约符号，
  与进程内真库**零符号冲突**。
- 头文件接口与上游保持 API 兼容，供 vendor-src 里的第三方源码（libfmq 等）直接 include。
- 修改这里必须同步跑 `registrar/build.sh` + 真机 deploy 验证。
