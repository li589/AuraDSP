# macOS 发行与公证规范 (.app & DMG)

本目录定义 AuraDSP 面向苹果 macOS 平台的代码签名、官方公证（Notarization）与 DMG 镜像分发标准。

---

## 1. 产物规范

- **DMG 安装镜像**：`dist/AuraDSP-v<ver>-macOS-Universal.dmg`
- **便携 Zip 包**：`dist/AuraDSP-v<ver>-macOS.zip`

---

## 2. 苹果代码签名与公证标准 (Code Signing & Notarization)

为绕过 macOS Gatekeeper 的拦截并确保普通用户可正常双击启动，必须严格按序完成：

1. **启用 Hardened Runtime**：
   编译与签名参数必须携带 `--options runtime` 并配置 `entitlements.plist`（允许音频捕获、JIT、网络通信）。
2. **递归签名全部 Framework 与动态库**：
   先签名 `AuraDSP.app/Contents/Frameworks/*.dylib`（包括 `libauradsp_engine.dylib`），最后签名主执行程序。
3. **调用 `notarytool` 提交公证**：
   ```bash
   xcrun notarytool submit "AuraDSP.dmg" --keychain-profile "AC_PASSWORD" --wait
   ```
4. **公证打标 (Staple)**：
   ```bash
   xcrun stapler staple "AuraDSP.dmg"
   ```

---

## 3. DMG 镜像制作

使用 `create-dmg` 工具制作具有品牌背景图与对齐格栅的标准磁盘镜像：
- 窗口尺寸：`600x400`
- 左侧图标：`AuraDSP.app`
- 右侧图标：指向 `/Applications` 文件夹的快捷方式软链接
- 引导提示：“拖动 AuraDSP 到 Applications 即可完成安装”

