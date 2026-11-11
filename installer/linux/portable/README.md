# Linux 便携包（tar.gz 形态）

AppImage 的等价补充形态，面向无 FUSE 环境与服务器场景：
解压得到 `AuraDSP-Linux-x64/`，运行其中 `./auradsp` 即启动
（bundle 原样 + 启动脚本 + 包内 README）。

构建：`build_portable.sh`（由 `../pack.sh` 调用），产出
`dist/AuraDSP-Linux-x64-v<ver>.tar.gz`。包内说明见
`README.portable.md`（会打进压缩包根目录）。
