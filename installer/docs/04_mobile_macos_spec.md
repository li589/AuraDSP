# Android 与 macOS 发行与签名规范方案

本文档涵盖移动端（Android）与苹果桌面端（macOS）的标准打包、代码签名、分包与产物输出规格。

> **状态：预留规格（不在当前发行范围）**。正式发行范围为 Windows + Linux（2026-11-06 owner 裁定，见 [01_distribution_architecture.md](01_distribution_architecture.md) 发布总则）；Android 为研究验证线、macOS 未实现。本文保留作未来立项时的规格参考，文内产物与流程不代表已交付能力。

---

## 1. Android 发行体系 (APK / AAB)

Android 平台的构建依托 Flutter 与 Gradle 体系。所有生成的安装包统一归集到 `dist/`。

### 1.1 产物矩阵
| 产物文件 | 格式 | 目标受众与场景 |
| :--- | :--- | :--- |
| `dist/AuraDSP-v<ver>-android-arm64-v8a.apk` | 单架构 APK | 现代主流 64 位手机与高端车载系统（体积最小） |
| `dist/AuraDSP-v<ver>-android-armeabi-v7a.apk` | 单架构 APK | 老旧 32 位设备与老款车载系统 |
| `dist/AuraDSP-v<ver>-android-universal.apk` | 通用胖 APK | GitHub Releases 供用户直接侧载（Sideloading），包含所有架构 |
| `dist/AuraDSP-v<ver>.aab` | Android App Bundle | Google Play 官方分发包（应用商店自动按设备拆分下发） |

### 1.2 签名与密钥管理 (Signing & Keystore)
1. **构建配置文件**：`app/auradsp_app/android/key.properties`。
2. **密钥环境变量**（严禁将私钥凭证硬编码入 Git 仓库）：
   ```properties
   storePassword=${ANDROID_KEYSTORE_PASSWORD}
   keyPassword=${ANDROID_KEY_PASSWORD}
   keyAlias=${ANDROID_KEY_ALIAS}
   storeFile=certs/android/release.keystore
   ```
3. **ProGuard / R8 混淆规则**：
   - 保持 C++ JNI / FFI 导出符号不被混淆。
   - 保持音频核心数据类序列化字段不被擦除。

### 1.3 命令行触发规格 (Pack Commands)
```bash
# 生成 Universal APK 与 AAB 并自动移动到 dist/
cd app/auradsp_app
flutter build apk --release --split-per-abi
flutter build apk --release # 通用包
flutter build appbundle --release
# 后续由 installer/android/pack.py 将 build/app/outputs/... 归集到 dist/
```

---

## 2. macOS 发行体系 (.app / DMG)

macOS 平台要求极其严格的代码签名（Code Signing）与苹果官方公证（Notarization），否则会在 Gatekeeper 拦截下提示“无法打开，因为无法验证开发者”。

### 2.1 产物矩阵
- `dist/AuraDSP-v<ver>-macOS-Universal.dmg`：苹果磁盘镜像，内含漂亮的项目背景图、带有光效的 `AuraDSP.app` 图标，以及指向 `/Applications` 文件夹的拖放快捷方式。
- `dist/AuraDSP-v<ver>-macOS.zip`：便携归档包。

### 2.2 签名与公证流程 (Hardened Runtime & Notarization)
1. **深度递归代码签名 (Deep Codesign)**：
   - 必须先对内部依赖的 C++ 动态库（如 `libauradsp_engine.dylib`）以及 Flutter 框架库单独签名：
     ```bash
     codesign --force --verify --verbose --sign "Developer ID Application: YourTeam" \
       --options runtime --entitlements entitlements.plist \
       "AuraDSP.app/Contents/Frameworks/..."
     ```
   - 最后对主执行程序与整个 App Bundle 签名：
     ```bash
     codesign --force --verify --verbose --sign "Developer ID Application: YourTeam" \
       --options runtime --entitlements entitlements.plist \
       "AuraDSP.app"
     ```
2. **苹果官方公证 (Notarization via notarytool)**：
   ```bash
   xcrun notarytool submit "AuraDSP.dmg" --keychain-profile "AC_PASSWORD" --wait
   # 公证通过后执行打标 (Staple)
   xcrun stapler staple "AuraDSP.dmg"
   ```
3. **DMG 生成工具选型**：
   采用主流开源工具 `create-dmg`，生成具有高质量窗口背景与图标网格对齐的标准 DMG 安装镜像。

