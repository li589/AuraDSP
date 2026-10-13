# docs/参考技术手册/ — 第三方参考手册区（本地清单）

> **本地只读参考区**：本目录下的 PDF 手册与克隆合计约 220 MB，且 Microsoft / Steinberg
> 文档未授予公开仓库镜像再分发许可（`windows-win32-api.pdf` 单文件 158.9 MB，
> 超出 GitHub 100 MB 硬限，入库即推送失败）。因此除本清单外全部内容
> `.gitignore` 排除——与 `source/` 同款铁律：只读快照，更新需重新下载并登记。
> 本文件随主库分发，作为手册区存在的凭证与索引。

登记日期：2026-10-14。所有条目仅供开发阅读参考；将文档内容抄入代码注释或
项目文档时注意各自版权声明。

## 手册清单

| 文件 / 目录 | 实测体积 | 来源（上游） | 许可 / 再分发 | 对 AuraDSP 的用途 |
|---|---|---|---|---|
| `windows-win32-api.pdf` | 158.9 MB | Microsoft Win32 API 全集（2026-10 下载） | Microsoft 版权，个人参考 | Win32 API 离线查阅（windows-drivers / 工具链） |
| `windows-hardware-drivers-audio.pdf` | 27.6 MB | Microsoft WDK 音频驱动文档 | 同上 | **音频驱动开发主参考**（portcls/WDM 对照） |
| `windows-wsl.pdf` | 17.9 MB | Microsoft WSL 文档 | 同上 | WSL 环境参考 |
| `cpp-windows-msvc-170.pdf` | 11.2 MB | Microsoft MSVC C++ 文档（离线包） | 同上 | MSVC 工具链 / C++ 标准库参考 |
| `windows-hardware-drivers-develop.pdf` | 5.3 MB | Microsoft WDK 驱动开发总览 | 同上 | WDK 构建与驱动模型总览 |
| `Steinberg ASIO Usage Guidelines.pdf` | 4.8 MB | Steinberg（ASIO 使用规范） | **Steinberg 专有许可，再分发受限** | 若评估 ASIO 宿主路线的合规依据 |
| `Steinberg ASIO SDK 2.3.pdf` | 0.8 MB | Steinberg ASIO SDK 2.3（2025-09） | **Steinberg 专有许可，再分发受限** | ASIO SDK 头文件/接口参考 |
| `android_guides_cn/` | 2.4 MB（200 文件） | `github.com/adisonhuang/android_guides_cn` @ `b138e44`（CodePath android_guides 中译 + 英文原文；cn/ 7 篇译文、en/ 192 篇原文） | 无 LICENSE 文件；上游为 CodePath 教学 wiki | Android 侧开发参考（`core/android/`、Flutter 宿主） |

合计约 **220 MB**。`android_guides_cn/` 的嵌套 `.git`（935K）已于 2026-10-14
按铁律剥除，可从上游重新克隆恢复。

## 维护规则

1. **只读**：不在此目录内改动、升级或提交任何文件；需要新版时重新下载/克隆，
   更新上表体积与 commit 后同步本清单。
2. **不入库**：除本 README 外全部 `.gitignore` 排除（见根 `.gitignore`
   `docs/参考技术手册/*` + `!docs/参考技术手册/README.md`）。
3. **版权红线**：Microsoft / Steinberg 文档与 android_guides_cn 均未授权公开
   镜像再分发——不得推送到公开仓库、不得随 release 附件分发；仅限本机开发参考。
4. **引用而非抄录**：项目中引用这些文档时给出来源文件名与章节即可，
   整段照抄入源码/文档同样受上述版权约束。
